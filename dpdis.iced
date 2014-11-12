ini = require 'node-ini'
BufferedStream = require 'bufferedstream'
moment = require 'moment'

cfg = ini.parseSync __dirname + '/../../config.ini'

CsvWriter = require '../../lib/CsvWriter'

# TODO: have a base models file that includes all of these?
DPDIS = require '../../lib/DPDIS'
Suppression = require '../../models/Suppression'
DpdisUpload = require '../../models/DpdisUpload'
SuppFile = require '../../models/SuppFile'
DpdisSearch = require '../../models/DpdisSearch'
Order = require '../../models/Order'
MailDrop = require '../../models/MailDrop'
ZipCode = require '../../models/ZipCode'

# FIXME: move these methods in to a class

exports.use = (socket) ->

	# Not allow access for the clients
	return if socket.handshake.user.Role == 'client'
	
	# FIXME: remove duplication
	socket.on 'dpdis:upload', (params, cb) ->
		dpdisUpload socket, params
		cb?()

	socket.on 'dpdis:search', (params, cb) ->
		params.CreatorID = socket.handshake.user.UserID

		# FIXME: authenticate socket.io connections and get User ID from handshake object
		params.SuppDays ?= 90
		params.Radius ?= 30

		newradius = parseInt(params.Radius) + 5	

		# Get zips out an extra 5 miles to ensure that we suppress all zips that are included by DPD
		await ZipCode.getZipList params.ZipList, newradius, defer err, zips
		return socket.emit 'error', err if err?

		params.zips = zips
	
		sfile = null
		if params.newsupp
			await newSupp params, defer sfile
		dpdisCount socket, sfile, params
		cb?()

	socket.on 'dpdis:counts', (params, cb) ->
		sendCounts socket, params.id

	socket.on 'dpdis:rerun', (params, cb) ->
		rerunSearch socket, params

newSupp = (params, cb) ->

	params.SuppName = "AutoBanc-#{params.ZipList}"
	params.Description ="Zip code suppression: #{params.ZipList}"

	if params.Radius
		params.SuppName += "-#{params.Radius}-miles"
		params.Description += ", radius #{params.Radius} miles"

	# Get drop date for this drop
	await MailDrop.findById params.DropID, defer drop
	params.DropDate = drop.DropDate

	# Check if there are any records available
	await SuppFile.checkRecords params, defer err, count
	return cb null if err or not count

	# Create the file
	await SuppFile.create params, defer sfile

	cb sfile

# TODO: move these later to a file in controllers subdir
dpdisUpload = (socket, suppfile, params, cb) ->

	logger.notice "DPDIS Upload"

	# Create the DPDIS entry
	params.SuppID = suppfile.SuppID 

	upload = new DpdisUpload params
	await upload.save defer err
	throw err if err?
	logger.debug "Created DpdisUpload with ID: #{upload.UploadID}"

	upload.zips = params.zips

	stream = new BufferedStream

	api = new DPDIS cfg.dpdis

	# Set listeners to update objectid and Order ID
	api.on 'objid', (objid) ->
		upload.setObjectId objid

	api.on 'fileinfo', (finfo) ->
		upload.setOrderId finfo.orderid
		socket.emit 'info', 'Done'
		cb? upload.UploadID, finfo.orderid, data.ponumber or socket.emit 'done'

	api.on 'error', (msg) ->
		socket.emit 'error', msg

	api.on 'info', (msg) ->
		logger.info msg
		socket.emit 'info', msg

	api.on 'status', (status) ->
		upload.Status = status
		upload.save()

	# Specify the PO Number and description
	data =
		ponumber: params.SuppName
		description: params.Description
		orderdate: moment(suppfile.DropDate).format 'M/DD/YYYY'

	api.uploadFile data, stream, (err) ->
		# TODO: compress this in to a function, or use errant
		if err
			logger.error err
			socket.emit 'error', err
			return

		cols = ['Address1', 'Zip']
		csv = new CsvWriter cols, stream

		[conn, query] = upload.getConnQuery()
		csv.streamResults conn, query

dpdisCount = (socket, suppfile, params) =>

	logger.notice "DPDIS Count"
	api = new DPDIS cfg.dpdis

	# TODO: fetch the Work Order to verify the ID
	#await Order.findById params.order, defer wo

	unless params.SearchName.match /\w/
		params.SearchName = "AutoBanc-#{params.ZipList}-#{params.Radius}-miles-#{params.CreditMin}-#{params.CreditMax}"

	search = new DpdisSearch params
	await search.save defer err
	throw err if err?

	socket.emit 'details', search.getObj()

	api.on 'info', (msg) ->
		logger.info msg
		socket.emit 'info', msg

	# FIXME: need validation here as well as on client
	api.on 'objid', (objid) ->
		search.objectid = objid
		search.save()

	api.on 'zipcounts', (data) ->
		for row in data
			await search.addCount row, defer ok

		socket.emit 'info', 'Done'
		socket.emit 'done'
		#getCountAndSend socket, search

	api.on 'status', (status) ->
		search.Status = status
		search.save()

	#if params.suppress is 'on'
	if suppfile
		await dpdisUpload socket, suppfile, params, defer uploadid, suppid, suppname

		params.suppid = suppid
		params.suppname = suppname
					
		search.SuppID = suppfile.SuppID
		search.UploadID = uploadid

		await search.save defer err

	api.search params

getCountAndSend = (socket, obj) ->
	obj.getCounts (data) ->

		# TODO: store this on the search itself (?) and pull other 
		#  details out to send as well in separate function

		# Get total records
		total = 0
		supp = 0
		for row in data
			total += parseInt row.Total
			supp += parseInt row.Suppressions

		socket.emit 'counts', 
			summary:
				total: total
				supp: supp
			zips: data

# Fetch the counts for a saved search & send to client
sendCounts = (socket, id) =>
	search = new DpdisSearch()
	search.id = id
	getCountAndSend socket, search

rerunSearch = (socket, params) =>

	# Get the previous search
	await DpdisSearch.findById params.SearchID, defer search

	# Copy the search parameters
	for key in ['CreditMin', 'CreditMax']
		params[key] = search[key]

	# FIXME: use the actual user ID
	params.SearchName = "AutoBanc-#{params.CreditMin}-#{params.CreditMax}-rerun-#{params.SearchID}"
	params.Created = new Date()
	params.CreatorID = 1
	params.Description = "Automated search"

	await SuppFile.newWithLimits params, defer err, supp

	params.SuppName = 'AutoBanc-#{supp.SuppID}-#{params.SuppDays}-days'

	dpdisCount socket, supp, params
