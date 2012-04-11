transaction = require '../transaction.server'
MemoryJournal = require '../adapters/journal-memory'
Serializer = require '../Serializer'

module.exports = creaateStm = ({store, journal}) ->
  if !journal
    journal = new MemoryJournal
  else if journal.constructor == Object
    {klass, opts} = journal
    klass ||= MemoryJournal
    journal = new klass opts
  return new Stm {store, journal}

Stm = (store: @_store, journal: @_journal) ->

  ## Ensure Serialization of Transactions to the DB ##
  # TODO: This algorithm will need to change when we go multi-process,
  # because we can't count on the version to increase sequentially
  store = @_store
  @_txnApplier = new Serializer
    withEach: (txn, ver, cb) ->
      store._finishCommit txn, ver, cb

  return

Stm::startId = (cb) ->
  @_journal.startId cb

Stm::commit = (txn, cb) ->
  ver = transaction.getVer txn
  if ver?
    if typeof ver isnt 'number'
      # In case of something like store.set(path, value, callback)
      return cb? new Error 'Version must be null or a number'
    eachCb = (err, loggedTxn, next) ->
      if ver? && (err = transaction.conflict txn, loggedTxn)
        return next err
      next null
  else
    eachCb = (_, _, next) -> next null

  journal = @_journal
  store = @_store
  txnApplier = @_txnApplier
  journal.eachTxnSince ver,
    meta:
      txn: txn
    each: eachCb
    done: (err, addParams) ->
      return cb? err if err

      # Copy txn to modify, to avoid mutating original
      journalTxn = copy txn
      journal.add journalTxn, addParams, (err, ver) ->
        return cb err if err
        transaction.setVer journalTxn, ver
        txnApplier.add txn, ver, cb

Stm::flush = (cb) -> @_journal.flush cb

Stm::disconnect = ->
  @_journal.disconnect?()

# The server journal generates a startId, as a reference point for racer to
# detect if the server journal has crashed. If the journal crashed, it may
# have lost transactions that the system had already accepted as committed
# (and therefore that the client will have already applied). This leads to
# invalid state because our client thinks its data has been accepted by the
# server; meanwhile, the server could be receiving and committing
# transactions that effectively use the same sequence of versions as these
# prior-accepted transactions. Therefore, there would be a fork of accepted
# states.
# TODO: Map the client's version number to the journal's and update
# the client with the new startId & version when possible
Stm::checkStartMarker = (clientStartId, cb) ->
  @_journal.startId (err, startId) ->
    return cb err if err
    if clientStartId != startId
      err = "clientStartId != startId (#{clientStartId} != #{startId})"
      return cb err
    cb null

Stm::version = (cb) ->
  @_journal.version cb

Stm::snapshotSince = ({ver, clientStartId, clientId}, cb) ->
  @checkStartMarker clientStartId, (err) =>
    return cb err if err
    @_journal.txnsSince ver, clientId, @_store._pubSub, (err, txns) ->
      return cb err if err
      cb null, {txns}

copy = (x) -> JSON.parse JSON.stringify x
