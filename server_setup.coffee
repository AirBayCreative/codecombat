express = require 'express'
path = require 'path'
authentication = require 'passport'
useragent = require 'express-useragent'
fs = require 'graceful-fs'
log = require 'winston'
compressible = require 'compressible'
geoip = require '@basicer/geoip-lite'

database = require './server/commons/database'
perfmon = require './server/commons/perfmon'
baseRoute = require './server/routes/base'
user = require './server/handlers/user_handler'
logging = require './server/commons/logging'
config = require './server_config'
auth = require './server/commons/auth'
routes = require './server/routes'
UserHandler = require './server/handlers/user_handler'
slack = require './server/slack'
Mandate = require './server/models/Mandate'
global.tv4 = require 'tv4' # required for TreemaUtils to work
global.jsondiffpatch = require 'jsondiffpatch'
global.stripe = require('stripe')(config.stripe.secretKey)
errors = require './server/commons/errors'
request = require 'request'
Promise = require 'bluebird'
Promise.promisifyAll(request, {multiArgs: true})

{countries} = require './app/core/utils'

productionLogging = (tokens, req, res) ->
  status = res.statusCode
  color = 32
  if status >= 500 then color = 31
  else if status >= 400 then color = 33
  else if status >= 300 then color = 36
  elapsed = (new Date()) - req._startTime
  elapsedColor = if elapsed < 500 then 90 else 31
  return null if status is 404 and /\/feedback/.test req.originalUrl  # We know that these usually 404 by design (bad design?)
  if (status isnt 200 and status isnt 201 and status isnt 204 and status isnt 304 and status isnt 302) or elapsed > 500
    return "\x1b[90m#{req.method} #{req.originalUrl} \x1b[#{color}m#{res.statusCode} \x1b[#{elapsedColor}m#{elapsed}ms\x1b[0m"
  null

developmentLogging = (tokens, req, res) ->
  status = res.statusCode
  color = 32
  if status >= 500 then color = 31
  else if status >= 400 then color = 33
  else if status >= 300 then color = 36
  elapsed = (new Date()) - req._startTime
  elapsedColor = if elapsed < 500 then 90 else 31
  s = "\x1b[90m#{req.method} #{req.originalUrl} \x1b[#{color}m#{res.statusCode} \x1b[#{elapsedColor}m#{elapsed}ms\x1b[0m"
  s += ' (proxied)' if req.proxied
  return s

setupDomainFilterMiddleware = (app) ->
  if config.isProduction
    unsafePaths = [
      /^\/web-dev-iframe\.html$/
      /^\/javascripts\/web-dev-listener\.js$/
    ]
    app.use (req, res, next) ->
      domainRegex = new RegExp("(.*\.)?(#{config.mainHostname}|#{config.unsafeContentHostname})")
      domainPrefix = req.host.match(domainRegex)?[1] or ''
      if _.any(unsafePaths, (pathRegex) -> pathRegex.test(req.path)) and (req.host isnt domainPrefix + config.unsafeContentHostname)
        res.redirect('//' + domainPrefix + config.unsafeContentHostname + req.path)
      else if not _.any(unsafePaths, (pathRegex) -> pathRegex.test(req.path)) and req.host is domainPrefix + config.unsafeContentHostname
        res.redirect('//' + domainPrefix + config.mainHostname + req.path)
      else
        next()

setupErrorMiddleware = (app) ->
  app.use (err, req, res, next) ->
    if err
      if err.name is 'MongoError' and err.code is 11000
        err = new errors.Conflict('MongoDB conflict error.')
      if err.code is 422 and err.response
        err = new errors.UnprocessableEntity(err.response)
      if err.code is 409 and err.response
        err = new errors.Conflict(err.response)

      # TODO: Make all errors use this
      if err instanceof errors.NetworkError
        return res.status(err.code).send(err.toJSON())

      if err.status and 400 <= err.status < 500
        res.status(err.status).send("Error #{err.status}")
        return

      res.status(err.status ? 500).send(error: "Something went wrong!")
      message = "Express error: #{req.method} #{req.path}: #{err.message} \n #{err.stack}"
      log.error "#{message}, stack: #{err.stack}"
      if global.testing
        console.log "#{message}, stack: #{err.stack}"
      slack.sendSlackMessage(message, ['ops'], {papertrail: true})
    else
      next(err)

setupExpressMiddleware = (app) ->
  if config.isProduction
    express.logger.format('prod', productionLogging)
    app.use(express.logger('prod'))
    app.use express.compress filter: (req, res) ->
      return false if req.headers.host is 'codecombat.com'  # CloudFlare will gzip it for us on codecombat.com
      compressible res.getHeader('Content-Type')
  else if not global.testing
    express.logger.format('dev', developmentLogging)
    app.use(express.logger('dev'))
  app.use('/'+config.buildInfo.sha, express.static(path.join(__dirname, 'public'), maxAge: 0))  # CloudFlare overrides maxAge, and we don't want local development caching.
  app.use(express.static(path.join(__dirname, 'public'), maxAge: 0))

  setupProxyMiddleware app # TODO: Flatten setup into one function. This doesn't fit its function name.

  app.use(express.favicon())
  app.use(express.cookieParser())
  app.use(express.bodyParser())
  app.use(express.methodOverride())
  app.use(express.cookieSession({
    key:'codecombat.sess'
    secret:config.cookie_secret
  }))

setupPassportMiddleware = (app) ->
  app.use(authentication.initialize())
  if config.picoCTF
    app.use authentication.authenticate('local', failureRedirect: config.picoCTF_login_URL)
    require('./server/lib/picoctf').init app
  else
    app.use(authentication.session())
  auth.setup()

setupCountryTaggingMiddleware = (app) ->
  app.use (req, res, next) ->
    return next() if req.country or req.user?.get('country')
    return next() unless ip = req.headers['x-forwarded-for'] or req.ip or req.connection.remoteAddress
    ip = ip.split(/,? /)[0]  # If there are two IP addresses, say because of CloudFlare, we just take the first.
    geo = geoip.lookup(ip)
    if countryInfo = _.find(countries, countryCode: geo?.country)
      req.country = countryInfo.country
    next()

setupCountryRedirectMiddleware = (app, country='china', host='cn.codecombat.com') ->
  hosts = host.split /;/g
  shouldRedirectToCountryServer = (req) ->
    reqHost = (req.hostname ? req.host).toLowerCase()  # Work around express 3.0
    return req.country is country and reqHost not in hosts and reqHost.indexOf(config.unsafeContentHostname) is -1

  app.use (req, res, next) ->
    if shouldRedirectToCountryServer(req) and hosts.length
      res.writeHead 302, "Location": 'http://' + hosts[0] + req.url
      res.end()
    else
      next()

setupOneSecondDelayMiddleware = (app) ->
  if(config.slow_down)
    app.use((req, res, next) -> setTimeout((-> next()), 1000))

setupMiddlewareToSendOldBrowserWarningWhenPlayersViewLevelDirectly = (app) ->
  isOldBrowser = (req) ->
    # https://github.com/biggora/express-useragent/blob/master/lib/express-useragent.js
    return false unless ua = req.useragent
    return true if ua.isiPad or ua.isiPod or ua.isiPhone or ua.isOpera
    return false unless ua and ua.Browser in ['Chrome', 'Safari', 'Firefox', 'IE'] and ua.Version
    b = ua.Browser
    try
      v = parseInt ua.Version.split('.')[0], 10
    catch TypeError
      log.error('ua.Version does not have a split function.', JSON.stringify(ua, null, '  '))
      return false
    return true if b is 'Chrome' and v < 17
    return true if b is 'Safari' and v < 6
    return true if b is 'Firefox' and v < 21
    return true if b is 'IE' and v < 11
    false

  app.use('/play/', useragent.express())
  app.use '/play/', (req, res, next) ->
    return next() if req.query['try-old-browser-anyway'] or not isOldBrowser req
    res.sendfile(path.join(__dirname, 'public', 'index_old_browser.html'))

setupRedirectMiddleware = (app) ->
  app.all '/account/profile/*', (req, res, next) ->
    nameOrID = req.path.split('/')[3]
    res.redirect 301, "/user/#{nameOrID}/profile"
    
setupFeaturesMiddleware = (app) ->
  app.use (req, res, next) ->
    # TODO: Share these defaults with run-tests.js
    req.features = features = {
      freeOnly: false
    }
    
    if config.picoCTF or req.session.featureMode is 'pico-ctf'
      features.playOnly = true

    if req.headers.host is 'cp.codecombat.com' or req.session.featureMode is 'code-play'
      features.freeOnly = true
      features.campaignSlugs = ['dungeon', 'forest', 'desert']
      features.playViewsOnly = true
      features.codePlay = true # for one-off changes. If they're shared across different scenarios, refactor

    if req.user
      { user } = req
      if user.get('country') in ['china'] and not (user.isPremium() or user.get('stripe'))
        features.freeOnly = true
        
    next()

setupSecureMiddleware = (app) ->
  # Cannot use express request `secure` property in production, due to
  # cluster setup.
  isSecure = ->
    return @secure or @headers['x-forwarded-proto'] is 'https'

  app.use (req, res, next) ->
    req.isSecure = isSecure
    next()

setupPerfMonMiddleware = (app) ->
  app.use perfmon.middleware

setupAPIDocs = (app) ->
  # TODO: Move this into routes, so they're consolidated
  YAML = require 'yamljs'
  swaggerDoc = YAML.load('./server/swagger.yaml')
  swaggerUi = require 'swagger-ui-express'
  app.use('/', swaggerUi.serve)
  app.use('/api-docs', swaggerUi.setup(swaggerDoc))

exports.setupMiddleware = (app) ->
  setupSecureMiddleware app
  setupPerfMonMiddleware app
  setupDomainFilterMiddleware app
  setupCountryTaggingMiddleware app
  setupCountryRedirectMiddleware app, 'china', config.chinaDomain
  setupCountryRedirectMiddleware app, 'brazil', config.brazilDomain
  setupMiddlewareToSendOldBrowserWarningWhenPlayersViewLevelDirectly app
  setupExpressMiddleware app
  setupAPIDocs app # should happen after serving static files, so we serve the right favicon
  setupPassportMiddleware app
  setupFeaturesMiddleware app
  setupOneSecondDelayMiddleware app
  setupRedirectMiddleware app
  setupAjaxCaching app
  setupErrorMiddleware app
  setupJavascript404s app

###Routing function implementations###

setupAjaxCaching = (app) ->
  # IE/Edge are more aggressive about caching than other browsers, so we'll override their caching here.
  # Assumes our CDN will override these with its own caching rules.
  app.get '/db/*', (req, res, next) ->
    return next() unless req.xhr
    # http://stackoverflow.com/questions/19999388/check-if-user-is-using-ie-with-jquery
    userAgent = req.header('User-Agent') or ""
    if userAgent.indexOf('MSIE ') > 0 or !!userAgent.match(/Trident.*rv\:11\.|Edge\/\d+/)
      res.header 'Cache-Control', 'no-cache, no-store, must-revalidate'
      res.header 'Pragma', 'no-cache'
      res.header 'Expires', 0
    next()

setupJavascript404s = (app) ->
  app.get '/javascripts/*', (req, res) ->
    res.status(404).send('Not found')
  app.get(/^\/?[a-f0-9]{40}/, (req, res) ->
    res.status(404).send('Wrong hash')
  )


setupFallbackRouteToIndex = (app) ->
  app.all '*', (req, res) ->
    fs.readFile path.join(__dirname, 'public', 'main.html'), 'utf8', (err, data) ->
      log.error "Error modifying main.html: #{err}" if err
      # insert the user object directly into the html so the application can have it immediately. Sanitize </script>
      user = if req.user then JSON.stringify(UserHandler.formatEntity(req, req.user)).replace(/\//g, '\\/') else '{}'

      Mandate.findOne({}).cache(5 * 60 * 1000).exec (err, mandate) ->
        if err
          log.error "Error getting mandate config: #{err}"
          configData = {}
        else
          configData =  _.omit mandate?.toObject() or {}, '_id'
        configData.picoCTF = config.picoCTF
        configData.production = config.isProduction
        configData.codeNinjas = (req.hostname ? req.host) is 'coco.code.ninja'
        domainRegex = new RegExp("(.*\.)?(#{config.mainHostname}|#{config.unsafeContentHostname})")
        domainPrefix = req.host.match(domainRegex)?[1] or ''
        configData.fullUnsafeContentHostname = domainPrefix + config.unsafeContentHostname
        configData.buildInfo = config.buildInfo
        data = data.replace '"environmentTag"', if config.isProduction then '"production"' else '"development"'
        data = data.replace /shaTag/g, config.buildInfo.sha
        data = data.replace '"serverConfigTag"', JSON.stringify configData
        data = data.replace('"userObjectTag"', user)
        data = data.replace('"serverSessionTag"', JSON.stringify(_.pick(req.session ? {}, 'amActually', 'featureMode')))
        data = data.replace('"featuresTag"', JSON.stringify(req.features))
        res.header 'Cache-Control', 'no-cache, no-store, must-revalidate'
        res.header 'Pragma', 'no-cache'
        res.header 'Expires', 0
        res.send 200, data

setupFacebookCrossDomainCommunicationRoute = (app) ->
  app.get '/channel.html', (req, res) ->
    res.sendfile path.join(__dirname, 'public', 'channel.html')

exports.setupRoutes = (app) ->
  routes.setup(app)
  app.use app.router

  baseRoute.setup app
  setupFacebookCrossDomainCommunicationRoute app
  setupFallbackRouteToIndex app

###Miscellaneous configuration functions###

exports.setupLogging = ->
  logging.setup()

exports.connectToDatabase = ->
  return if config.proxy
  database.connect()

exports.setupMailchimp = ->
  mcapi = require 'mailchimp-api'
  mc = new mcapi.Mailchimp(config.mail.mailchimpAPIKey)
  GLOBAL.mc = mc

exports.setExpressConfigurationOptions = (app) ->
  app.set('port', config.port)
  app.set('views', __dirname + '/app/views')
  app.set('view engine', 'jade')
  app.set('view options', { layout: false })
  app.set('env', if config.isProduction then 'production' else 'development')
  app.set('json spaces', 0) if config.isProduction

setupProxyMiddleware = (app) ->
  return if config.isProduction
  return unless config.proxy
  httpProxy = require 'http-proxy'
  proxy = httpProxy.createProxyServer({
    target: 'https://direct.codecombat.com'
    secure: false
  })
  log.info 'Using dev proxy server'
  app.use (req, res, next) ->
    req.proxied = true
    proxy.web req, res, (e) ->
      console.warn("Failed to proxy: ", e)
      res.status(502).send({message: 'Proxy failed'})
