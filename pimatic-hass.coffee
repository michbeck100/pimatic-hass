module.exports = (env) =>
  Promise = env.require 'bluebird'
  mqtt = require('mqtt')
  _ = require("lodash")
  switchAdapter = require('./adapters/switch')(env)
  lightAdapter = require('./adapters/light')(env)
  #rgblightAdapter = require('./adapters/rgblight')(env)
  sensorAdapter = require('./adapters/sensor')(env)
  binarySensorAdapter = require('./adapters/binarysensor')(env)
  #shutterAdapter = require('./adapters/shutter')(env)
  variablesAdapter = require('./adapters/variables')(env)

  class HassPlugin extends env.plugins.Plugin

    init: (app, @framework, @config) =>

      pluginConfigDef = require("./hass-config-schema.coffee")
      deviceConfigDef = require("./device-config-schema")
      @framework.deviceManager.registerDeviceClass('HassDevice', {
        configDef: deviceConfigDef.HassDevice,
        createCallback: (config, lastState) => new HassDevice(config, lastState, @framework, @)
      })


  class HassDevice extends env.devices.PresenceSensor

    constructor: (@config, lastState, @framework, @plugin) ->
      @id = @config.id
      @name = @config.name

      if @_destroyed
        return

      @framework.on 'destroy', () =>
        @destroy()
        #for i, _adapter of @adapters
        #  _adapter.setAvailability(off)        

      
      ###
      # not possible, HassDevice need for this to be the last device in config.
      for _d in @config.devices
        do(_d) =>
          _d = _d.trim()
          _dev = @framework.deviceManager.getDeviceById(_d)
          unless _dev?
            env.logger.debug "Pimatic device #{_d} does not exsist"
      ###

      @discovery_prefix = @plugin.config.discovery_prefix ? @plugin.pluginConfigDef.discovery_prefix.default

      @mqttOptions =
          host: @plugin.config.mqttServer ? ""
          port: @plugin.config.mqttPort ? @plugin.pluginConfigDef.mqttPort.default
          username: @plugin.config.mqttUsername ? ""
          password: @plugin.config.mqttPassword ? ""
          clientId: 'pimatic_' + Math.random().toString(16).substr(2, 8)
          #protocolVersion: 4 # @plugin.config?.mqttProtocolVersion or 4
          #queueQoSZero: true
          keepalive: 180
          clean: true
          rejectUnauthorized: false
          reconnectPeriod: 15000
          debug: true # @plugin.config?.debug or false
      ###
      if @plugin.config.mqttProtocol == "MQTTS"
        #@mqttOptions["protocolId"] = "MQTTS"
        @mqttOptions["protocol"] = "mqtts"
        @mqttOptions.port = 8883
        @mqttOptions["keyPath"] = @plugin.config?.certPath or @plugin.configProperties.certPath.default
        @mqttOptions["certPath"] = @plugin.config?.keyPath or @plugin.configProperties.keyPath.default
        @mqttOptions["ca"] = @plugin.config?.caPath or @plugin.configProperties.caPath.default
      else
      ###
      @mqttOptions["protocolId"] = "MQTT" # @config?.mqttProtocol or @plugin.configProperties.mqttProtocol.default

      @framework.variableManager.waitForInit()
      .then ()=>
        @client = new mqtt.connect(@mqttOptions)
        env.logger.debug "Connecting to MQTT server..."

        @client.on 'connect', () =>
          env.logger.debug "Successfully connected to MQTT server"
          @_initDevices()
          .then((nrOfDevices) =>
            if nrOfDevices > 0
              @_setPresence(true)
              @client.subscribe @discovery_prefix + "/#" , (err, granted) =>
                if err
                  env.logger.error "Error in initdevices " + err
                  return
                env.logger.debug "Succesfully subscribed to #{@discovery_prefix}: " + JSON.stringify(granted,null,2)
                for i, _adapter of @adapters
                  _adapter.publishDiscovery()
                  _adapter.publishState()
          ).catch((err)=>
            env.logger.error "Error initdevices: " + err
          )

        @client.on 'message', (topic, message, packet) =>
          #env.logger.debug "Packet received " + JSON.stringify(packet.payload,null,2)
          if topic.endsWith("/config")
            env.logger.debug "Config received no action: " + String(packet.payload)
            return
          _adapter = @getAdapter(topic)
          env.logger.debug "message received with topic: " + topic
          if _adapter?
            newState = _adapter.handleMessage(packet)
          if topic.startsWith(@discovery_prefix + "/status")
            if String packet.payload is "offline"
              @_setPresence(false)
            if String packet.payload is "online"
              @_setPresence(true)
              env.logger.debug "RePublish devices to Hass"
              for i, _adapter of @adapters
                _adapter.publishDiscovery()
                _adapter.publishState()              
            #env.logger.debug "Hass status message received, status: " + String packet.payload

        @client.on 'pingreq', () =>
          env.logger.debug "Ping request, no aswer YET"
          # send a pingresp
          #@client.pingresp()

        # connection error handling
        @client.on 'close', () => 
          @_setPresence(false)

        @client.on 'error', (err) => 
          env.logger.error "error: " + err
          @_setPresence(false)

        @client.on 'disconnect', () => 
          env.logger.info "Client disconnect"
          @_setPresence(false)


      @framework.on 'deviceDeleted', (device) =>
      for i, _adapter of @adapters
        if _adapter.id is device.id
          _adapter.destroy()
          delete @adapters[i]

      ###
      @framework.on 'deviceAdded', (device) =>
        @framework.variableManager.waitForInit()
        .then(() =>
          env.logger.info "deviceAdded '#{device.id}' checked for autodiscovery"
          unless @adapters[device.id]?
            @_addDevice(device)
            .then((newAdapter) =>
              env.logger.info "device '#{newAdapter.id}' added"
              newAdapter.publishDiscovery()
              .then(() =>
                newAdapter.publishState()
              ).catch((err) =>
              )
            ).catch((err)=>
            )
        ).catch((err) =>
        )
      ###

      @framework.on 'deviceChanged', (device) =>
        if device.id is @id
          # the HassDevice is changed
          env.logger.debug "HassDevice changed"
        else
          # one of the used device can be changed
          if @adapters[device.id]?
              @adapters[device.id].update(device)

      super()

    _addDevice: (device) =>
      return new Promise((resolve,reject) =>
        if @adapters[device.id]?
          reject("adapter already exists")
        #if device.config.class is "MilightRGBWZone" or device.config.class is "MilightFullColorZone"
        #  _newAdapter = new rgblightAdapter(device, @client, @discovery_prefix)
        #  @adapters[device.id] = _newAdapter
        #  resolve(_newAdapter)
        if device instanceof env.devices.DimmerActuator or (device.hasAttribute("dimlevel") and device.hasAttribute("state"))
          _newAdapter = new lightAdapter(device, @client, @discovery_prefix)
          @adapters[device.id] = _newAdapter
          resolve(_newAdapter)
        else if device instanceof env.devices.SwitchActuator
          _newAdapter = new switchAdapter(device, @client, @discovery_prefix)
          @adapters[device.id] = _newAdapter
          resolve(_newAdapter)
        else if device instanceof env.devices.Sensor and device.hasAttribute("temperature") and device.hasAttribute("humidity")
          _newAdapter = new sensorAdapter(device, @client, @discovery_prefix)
          @adapters[device.id] = _newAdapter
          resolve(_newAdapter)
        else if device instanceof env.devices.Sensor and (device.hasAttribute("contact") or device.hasAttribute("presence"))
          _newAdapter = new binarySensorAdapter(device, @client, @discovery_prefix)
          @adapters[device.id] = _newAdapter
          resolve(_newAdapter)
        else if device.config.class is "VariablesDevice"
          _newAdapter = new variablesAdapter(device, @client, @discovery_prefix)
          @adapters[device.id] = _newAdapter
          resolve(_newAdapter)
        else if device instanceof env.devices.HeatingThermostat
          throw new Error "Device type HeatingThermostat not implemented"
        else if device instanceof env.devices.ShutterController
          throw new Error "Device type ShutterController not implemented"
        else
          throw new Error "Init: Device type of device #{device.id} does not exist"
        #env.logger.info "Devices: " + JSON.stringify(@adapters,null,2)
        reject()
      )

    _initDevices: () =>
      return new Promise((resolve,reject) =>
        @adapters = {}
        nrOfDevices = 0
        for _device,i in @config.devices
          env.logger.debug "InitDevices _device: " + _device
          device = @framework.deviceManager.getDeviceById(_device)
          if device?
            env.logger.debug "Found device: " + device.id
            do (device) =>
              nrOfDevices += 1
              @_addDevice(device)
              .then(()=>
                env.logger.debug "Device '#{device.id}' added"
              ).catch((err)=>
                env.logger.error "Error " + err
                reject()
              )
          else
            env.logger.info "Device '#{_device}' not found, please remove from config!"
        resolve(nrOfDevices)
      )

    getAdapter: (topic) =>
      try
        _items = topic.split('/')
        if _items[0] isnt @discovery_prefix
          env.logger.debug "#{@discovery_prefix} not found " + _items[0]
          return null
        if _items[1]?
          _adapter = @adapters[_items[1]]
          if !_adapter?
            env.logger.debug "Device '#{__items[1]}'' not found"
          else
            return @adapters[_items[1]]
        else
          return null
      catch err
        return null

    destroy: () =>
      for i, _adapter of @adapters
        _adapter.destroy()
        delete @adapters[i]
      try
        @client.end()
      catch err
      super()

  return new HassPlugin
