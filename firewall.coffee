passport = require('passport')
passportLocalStrategy = require('passport-local').Strategy
User = require('../models/User')
connect = require('express/node_modules/connect')
parseSignedCookie = connect.utils.parseSignedCookie
cookie = require('express/node_modules/cookie')

# Route with anonymous authentication
white_list = [
	/^\/login/,
	/^\/forgot-password/,
	/^\/reset-password/,
	/^\/register/,
	/^\/verify-email/,
	/^\/approve-count/,
	/^\/zips\/zipboundary/
]

# Access control for the routes
# pattern - regexp for the url path
# roles - array of user roles who can access this route
access_control = [
	{
		pattern: /^\/orders\/import-file\//
		roles : ['admin','supplier']
	},
	{
		pattern: /^\/orders\/delete-file\//
		roles : ['admin','supplier']
	},
	{
		pattern: /^\/orders\/restore-file\//
		roles : ['admin','supplier']
	},
	{
		pattern: /^\/orders\/change-drop-status\//
		roles : ['admin','supplier']
	},
	{
		pattern: /^\/orders/ 
		roles : ['admin','client','supplier']
	},
	{
		pattern: /^\/supp\//
		roles : ['admin','supplier']
	},
	{
		pattern: /^\/users/ 
		roles : ['admin']
	},
]

# Configure the firewall
# Call it like 'app.use(firewall.configure(app))' before the app.use(app.router)
# - initialize
# - init the new strategy
# - define the serialize and deserialize methods
exports.configure = (app)->

	# App middlewares
	app.configure ->
		app.use passport.initialize()
		app.use passport.session()

	# Authentication configuration
	passport.use new passportLocalStrategy (username, password, done) ->

		User.search UserName: username ,(users) ->

			# User is found
			if not users or users.length == 0
				return done null, false, message: 'Incorrect username.'
			user = new User users[0]
			# Encode and verify the entered password
			if user.encodePassword(password) isnt user.Password
				return done null, false, message: 'Incorrect password.'
				
			return done null, user

	# User serialization: save the ID only
	passport.serializeUser (user, done)->
		done(null, user.UserID)

	# User unserialization: query to DB to find the full search info
	passport.deserializeUser (id, done)->

		User.findById_firewall id, (err, user) ->
			# Detect the role of the user. Role will be saved in Role property of user object
			user.detectRole (role) ->
				done(err,user)

	# Authentication
	app.use (req, res, next)->
		for pattern in white_list when pattern.test req.path
			return next()

		exports.ensureAuthenticated req, res, next

	# Authorization
	app.use (req, res, next)->
		for firewall in access_control when firewall.pattern.test req.path
			middleware = exports.ensureAuthorized firewall.roles
			return middleware req, res, next

		next()

# Simple route middleware to ensure user is authenticated.
# Use this route middleware on any resource that needs to be protected. If
# the request is authenticated (typically via a persistent login session),
# the request will proceed. Otherwise, the user will be redirected to the
# login page.
exports.ensureAuthenticated = (req, res, next) ->
	return next() if req.isAuthenticated()
	res.redirect('/login')

# Simple route middleware to ensure user is authorized.
exports.ensureAuthorized = (roles) ->
	return (req, res, next)->

		return next() if req.user.Role in roles

		logger.warning "401 Unauthorized access: #{req.user.UserName} with role '#{req.user.Role}' tried to access #{req.originalUrl}"

		exports.sendUnauthorizedRes res

# Send the response with 401 status code
exports.sendUnauthorizedRes = (res) ->
	res.send '401 Unauthorized', 401

# Authenticate the socket connections
exports.configureSocketio = (app, io, sessionStorage) ->

	# Authenticate socket connection
	io.set 'authorization', (handshakeData, ioCb)->

		# If cookie isn't passed, turn down the connection with a message
		# And leave the function.
		return ioCb 'Socket.IO: No cookie transmitted.', false unless handshakeData.headers.cookie?

		# If there is, parse the cookie
		handshakeData.cookie = cookie.parse handshakeData.headers.cookie
		
		# Check the Session key in the cookies
		return ioCb 'Socket.IO: Not valid session ID.', false unless handshakeData.cookie[app.get('cfg').web['session.key']]?

		# Note that you will need to use the same key to grad the
		# Session id, as you specified in the Express setup.
		handshakeData.sessionID = parseSignedCookie(handshakeData.cookie[app.get('cfg').web['session.key']], app.get('cfg').web['session.secret'])
		
		# Session is invalid
		return ioCb 'Socket.IO: Can\'t parse signed cookie.', false if handshakeData.sessionID is false

		# Find the session info by ID
		sessionStorage.get handshakeData.sessionID, (err, session) ->

			# Check the user ID in the passport object
			return ioCb 'Socket.IO: User isn\'t authenticated', false unless session?.passport.user?

			# Search the user in the DB
			User.findById session.passport.user, (user, err) ->
				return ioCb 'Socket.IO: ' + error, false if err?
				return ioCb 'Socket.IO: Can\'t find user in DB', false unless user
				
				# Detect the role. Access it using the socket.handshake.user.Role
				user.detectRole (role) ->

					handshakeData.user = user

					# Accept the incoming connection
					ioCb null, true

	io.sockets.on 'connection', (socket) ->
		logger.debug "Socket.IO connection: #{socket.id} , user: #{socket.handshake.user.UserName} with #{socket.handshake.user.Role} role"
