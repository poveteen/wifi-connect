Promise = require('bluebird')
connman = Promise.promisifyAll(require('connman-simplified')())
express = require('express')
app = express()
bodyParser = require('body-parser')
iptables = Promise.promisifyAll(require('./iptables'))
spawn = require('child_process').spawn
os = require('os')
async = require('async')

ssid = process.env.SSID or 'ResinAP'
passphrase = process.env.PASSPHRASE or null

port = process.env.PORT or 8080

server = null
ssidList = null
dnsServer = null

ignore = ->

getIptablesRules = (callback) ->
	async.retry {times: 100, interval: 100}, (cb) ->
		Promise.try ->
			os.networkInterfaces().tether[0].address
		.nodeify(cb)
	, (err, myIP) ->
		return callback(err) if err?
		callback null, [
				table: 'nat'
				rule: 'PREROUTING -i tether -j TETHER'
			,
				table: 'nat'
				rule: "TETHER -p tcp --dport 80 -j DNAT --to-destination #{myIP}:8080"
			,
				table: 'nat'
				rule: "TETHER -p tcp --dport 443 -j DNAT --to-destination #{myIP}:8080"
			,
				table: 'nat'
				rule: "TETHER -p udp --dport 53 -j DNAT --to-destination #{myIP}:53"
		]


startServer = (wifi) ->
	console.log('Getting networks list')
	wifi.getNetworksAsync().then (list) ->
		ssidList = list
		wifi.openHotspotAsync(ssid, passphrase)
	.then ->
		console.log('Hotspot enabled')
		dnsServer = spawn('named', ['-f'])
		getIptablesRules (err, iptablesRules) ->
			throw err if err?
			iptables.appendManyAsync(iptablesRules)
			.then ->
				console.log('Captive portal enabled')
				server = app.listen port, (err) ->
					throw err if err?
					console.log('Server listening')

console.log('Starting node connman app')
manageConnection = (retryCallback) ->
	connman.initAsync()
	.then ->
		console.log('Connman initialized')
		connman.initWiFiAsync()
	.spread (wifi, properties) ->
		wifi = Promise.promisifyAll(wifi)
		console.log('WiFi initialized')

		app.use(bodyParser())
		app.use(express.static(__dirname + '/public'))
		app.get '/ssids', (req, res) ->
			res.send(ssidList)
		app.post '/connect', (req, res) ->
			if not (req.body.ssid? and req.body.passphrase?)
				return res.sendStatus(400)
			console.log('Selected ' + req.body.ssid)
			res.send('OK')
			server.close()
			iptables.deleteAsync({ table: 'nat', rule: 'PREROUTING -i tether -j TETHER'})
			.catch(ignore)
			.then ->
				iptables.flushAsync('nat', 'TETHER')
			.catch(ignore)
			.then ->
				dnsServer.kill()
				console.log('Server closed and captive portal disabled')
				wifi.joinWithAgentAsync(req.body.ssid, req.body.passphrase)
			.then ->
				console.log('Joined! Exiting.')
				retryCallback()
			.catch (err) ->
				console.log('Error joining network', err, err.stack)
				return startServer(wifi)

		app.use (req, res) ->
			res.redirect('/')

		# Create TETHER iptables chain (will silently fail if it already exists)
		iptables.createChainAsync('nat', 'TETHER')
		.catch(ignore)
		.then ->
			iptables.deleteAsync({ table: 'nat', rule: 'PREROUTING -i tether -j TETHER'})
		.catch(ignore)
		.then ->
			iptables.flushAsync('nat', 'TETHER')
		.then ->
			if !properties.connected
				console.log('Trying to join wifi')
				wifi.joinFavoriteAsync()
				.then ->
					console.log('Joined! Exiting.')
					retryCallback()
				.catch (err) ->
					startServer(wifi)

			else
				console.log('Already connected')
				retryCallback()
	.catch (err) ->
		console.log(err)
		return retryCallback(err)

async.retry {times: 10, interval: 1000}, manageConnection, (err) ->
	throw err if err?
	process.exit()
