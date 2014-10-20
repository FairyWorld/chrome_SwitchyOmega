### @module omega-target/options ###
Promise = require 'bluebird'
Log = require './log'
Storage = require './storage'
OmegaPac = require 'omega-pac'
jsondiffpatch = require 'jsondiffpatch'

class Options
  ###*
  # The entire set of options including profiles and other settings.
  # @typedef OmegaOptions
  # @type {object}
  ###

  ###*
  # All the options, in a map from key to value.
  # @type OmegaOptions
  ###
  _options: {}
  _storage: null
  _state: null
  _currentProfileName: null
  _watchingProfiles: {}
  _tempProfile: null
  _tempProfileRules: {}
  _tempProfileRulesByProfile: {}
  fallbackProfileName: 'system'
  _isSystem: false
  debugStr: 'Options'

  ready: null

  ProfileNotExistError: class ProfileNotExistError extends Error
    constructor: (@profileName) ->
      super.constructor("Profile #{@profileName} does not exist!")

  constructor: (@_options, @_storage, @_state, @log) ->
    @_storage ?= Storage()
    @_state ?= Storage()
    @log ?= Log
    if @_options?
      @ready = Promise.resolve(@_options)
    else
      @ready = @_storage.get(null)
    @ready = @ready.then((options) =>
      @upgrade(options).then(([options, changes]) =>
        modified = {}
        removed = []
        for own key, value of changes
          if typeof value == 'undefined'
            removed.push(value)
          else
            modified[key] = value
        @_storage.set(modified).then(=>
          @_storage.remove(removed)
        ).return(options)
      ).catch (ex) =>
        @log.error(ex.stack)
        @reset()
    ).then((options) =>
      @_options = options
      @_watch()
    ).then(=>
      if @_options['-startupProfileName']
        @applyProfile(@_options['-startupProfileName'])
      else
        @_state.get({
          'currentProfileName': @fallbackProfileName
          'isSystemProfile': false
        }).then (st) =>
          if st['isSystemProfile']
            @applyProfile('system')
          else
            @applyProfile(st['currentProfileName'] || @fallbackProfileName)
    ).catch((err) =>
      if not err instanceof ProfileNotExistError
        @log.error(err)
      @applyProfile(@fallbackProfileName)
    ).catch((err) =>
      @log.error(err)
    ).then => @getAll()

    @ready.then =>
      if @_options['-downloadInterval'] > 0
        @updateProfile()

  toString: -> "<Options>"

  ###*
  # Upgrade options from previous versions.
  # For now, this method only supports schemaVersion 1 and 2. If so, it upgrades
  # the options to version 2 (the latest version). Otherwise it rejects.
  # It is recommended for the derived classes to call super() two times in the
  # beginning and in the end of the implementation to check the schemaVersion
  # and to apply future upgrades, respectively.
  # Example: super(options).catch -> super(doCustomUpgrades(options), changes)
  # @param {?OmegaOptions} options The legacy options to upgrade
  # @param {{}={}} changes Previous pending changes to be applied. Default to
  # an empty dictionary. Please provide this argument when calling super().
  # @returns {Promise<[OmegaOptions, {}]>} The new options and the changes.
  ###
  upgrade: (options, changes) ->
    changes ?= {}
    version = options?['schemaVersion']
    if version == 1
      autoDetectUsed = false
      OmegaPac.Profiles.each options, (key, profile) ->
        if not autoDetectUsed
          refs = OmegaPac.Profiles.directReferenceSet(profile)
          if refs['+auto_detect']
            autoDetectUsed = true
      if autoDetectUsed
        options['+auto_detect'] = OmegaPac.Profiles.create(
          name: 'auto_detect'
          profileType: 'PacProfile'
          pacUrl: 'http://wpad/wpad.dat'
          color: '#00cccc'
        )
      version = changes['schemaVersion'] = options['schemaVersion'] = 2
    if version == 2
      # Current schemaVersion.
      Promise.resolve([options, changes])
    else
      Promise.reject new Error("Invalid schemaVerion #{version}!")

  ###*
  # Reset the options to the given options or initial options.
  # @param {?OmegaOptions} options The options to set. Defaults to initial.
  # @returns {Promise<OmegaOptions>} The options just applied
  ###
  reset: (options) ->
    @log.method('Options#reset', this, arguments)
    if not options
      options = @getDefaultOptions()
    if typeof options == 'string'
      if options[0] != '{'
        try
          Buffer = require('buffer').Buffer
          options = new Buffer(options, 'base64').toString('utf8')
        catch
          options = null
      options = try JSON.parse(options)
    if not options
      return Promise.reject new Error('Invalid options!')
    @upgrade(options).then ([opt]) =>
      @_storage.remove().then(=>
        @_storage.set(opt)
      ).then -> opt

  ###*
  # Return the default options used initially and on resets.
  # @returns {?OmegaOptions} The default options.
  ###
  getDefaultOptions: -> require('./default_options')()

  ###*
  # Return all options.
  # @returns {?OmegaOptions} The options.
  ###
  getAll: -> @_options

  ###*
  # Get profile by name.
  # @returns {?{}} The profile, or undefined if no such profile.
  ###
  profile: (name) -> OmegaPac.Profiles.byName(name, @_options)

  ###*
  # Apply the patch to the current options.
  # @param {jsondiffpatch} patch The patch to apply
  # @returns {Promise<OmegaOptions>} The updated options
  ###
  patch: (patch) ->
    return unless patch
    @log.method('Options#patch', this, arguments)
    
    @_options = jsondiffpatch.patch(@_options, patch)
    # Only set the keys whose values have changed.
    changes = {}
    removed = []
    for own key, delta of patch
      if delta.length == 3 and delta[1] == 0 and delta[2] == 0
        # [previousValue, 0, 0] indicates that the key was removed.
        changes[key] = undefined
      else
        changes[key] = @_options[key]

    @_setOptions(changes)

  _setOptions: (changes, args) =>
    removed = []
    checkRev = args?.checkRevision ? false
    profilesChanged = false
    currentProfileAffected = false
    for own key, value of changes
      if typeof value == 'undefined'
        delete @_options[key]
        removed.push(key)
        if key[0] == '+'
          profilesChanged = true
          if key == '+' + @_currentProfileName
            currentProfileAffected = 'removed'
      else
        if key[0] == '+'
          if checkRev and @_options[key]
            result = OmegaPac.Revision.compare(@_options[key].revision,
              value.revision)
            continue if result >= 0
          profilesChanged = true
        @_options[key] = value
      if not currentProfileAffected and @_watchingProfiles[key]
        currentProfileAffected = 'changed'
    switch currentProfileAffected
      when 'removed'
        @applyProfile(@fallbackProfileName)
      when 'changed'
        @applyProfile(@_currentProfileName)
      else
        @_setAvailableProfiles() if profilesChanged
    if args?.persist ? true
      for key in removed
        delete changes[key]
      @_storage.set(changes).then =>
        @_storage.remove(removed)
        return @_options

  _watch: ->
    handler = (changes) =>
      if changes
        @_setOptions(changes, {checkRevision: true, persist: false})
      else
        # Initial update.
        changes = @_options

      refresh = changes['-refreshOnProfileChange']
      if refresh?
        @_state.set({'refreshOnProfileChange': refresh})

      if changes['-enableQuickSwitch']? or changes['-quickSwitchProfiles']?
        if @_options['-enableQuickSwitch']
          profiles = @_options['-quickSwitchProfiles']
          if profiles.length >= 2
            @setQuickSwitch(profiles)
          else
            @setQuickSwitch(null)
        else
          @setQuickSwitch(null)
      if changes['-downloadInterval']?
        @schedule 'updateProfile', @_options['-downloadInterval'], =>
          @updateProfile()

    handler()
    @_storage.watch null, handler

  ###*
  # @callback watchCallback
  # @param {Object.<string, {}>} changes A map from keys to values.
  ###

  ###*
  # Watch for any changes to the options
  # @param {watchCallback} callback Called everytime the value of a key changes
  # @returns {function} Calling the returned function will stop watching.
  ###
  watch: (callback) -> @_storage.watch null, callback

  ###*
  # Get PAC script for profile.
  # @param {?string|Object} profile The name of the profile, or the profile.
  # @param {bool=false} compress Compress the script if true.
  # @returns {String} The compiled
  ###
  pacForProfile: (profile, compress = false) ->
    ast = OmegaPac.PacGenerator.script(@_options, profile)
    if compress
      ast = OmegaPac.PacGenerator.compress(ast)
    Promise.resolve OmegaPac.PacGenerator.ascii(ast.print_to_string())

  _setAvailableProfiles: ->
    profile = if @_currentProfileName then @currentProfile() else null
    profiles = {}
    currentIncludable = profile && OmegaPac.Profiles.isIncludable(profile)
    if not profile or not OmegaPac.Profiles.isInclusive(profile)
      results = []
    OmegaPac.Profiles.each @_options, (key, profile) ->
      profiles[key] =
        name: profile.name
        profileType: profile.profileType
        color: profile.color
        builtin: !!profile.builtin
      if currentIncludable and OmegaPac.Profiles.isIncludable(profile)
        results?.push(profile.name)
    if profile and OmegaPac.Profiles.isInclusive(profile)
      results = OmegaPac.Profiles.validResultProfilesFor(profile, @_options)
      results = results.map (profile) -> profile.name
    @_state.set({
      'availableProfiles': profiles
      'validResultProfiles': results
    })

  ###*
  # Apply the profile by name.
  # @param {?string} name The name of the profile, or null for default.
  # @param {?{}} options Some options
  # @param {bool=true} options.proxy Set proxy for the applied profile if true
  # @param {bool=false} options.system Whether options is in system mode.
  # @param {{}=undefined} options.reason will be passed to currentProfileChanged
  # @returns {Promise} A promise which is fulfilled when the profile is applied.
  ###
  applyProfile: (name, options) ->
    @log.method('Options#applyProfile', this, arguments)
    profile = OmegaPac.Profiles.byName(name, @_options)
    if not profile
      return Promise.reject new ProfileNotExistError(name)

    @_currentProfileName = profile.name
    @_isSystem = options?.system || (profile.profileType == 'SystemProfile')
    @_watchingProfiles = OmegaPac.Profiles.allReferenceSet(profile, @_options)

    @_state.set({
      'currentProfileName': @_currentProfileName
      'isSystemProfile': @_isSystem
      'currentProfileCanAddRule': profile.rules?
    })
    @_setAvailableProfiles()

    @currentProfileChanged(options?.reason)
    if options? and options.proxy == false
      return Promise.resolve()
    if @_tempProfile?
      if @_tempProfile.defaultProfileName != profile.name
        @_tempProfile.defaultProfileName = profile.name
        @_tempProfile.color = profile.color
        OmegaPac.Profiles.updateRevision(@_tempProfile)

      removedKeys = []
      for own key, list of @_tempProfileRulesByProfile
        if not OmegaPac.Profiles.byKey(key, @_options)
          removedKeys.push(key)
          for rule in list
            rule.profileName = null
            @_tempProfile.rules.splice(@_tempProfile.rules.indexOf(rule), 1)
      if removedKeys.length > 0
        for key in removedKeys
          delete @_tempProfileRulesByProfile[key]
        OmegaPac.Profiles.updateRevision(@_tempProfile)

      @_watchingProfiles = OmegaPac.Profiles.allReferenceSet(@_tempProfile,
        @_options)
      @applyProfileProxy(@_tempProfile)
    else
      @applyProfileProxy(profile)

  ###*
  # Get the current applied profile.
  # @returns {{}} The current profile
  ###
  currentProfile: ->
    if @_currentProfileName
      OmegaPac.Profiles.byName(@_currentProfileName, @_options)
    else
      @_externalProfile

  ###*
  # Return true if in system mode.
  # @returns {boolean} True if system mode is activated
  ###
  isSystem: -> @_isSystem

  ###*
  # Set proxy settings based on the given profile.
  # In base class, this method is not implemented and will always reject.
  # @param {{}} profile The profile to apply
  # @returns {Promise} A promise which is fulfilled when the proxy is set.
  ###
  applyProfileProxy: (profile) ->
    Promise.reject new Error('not implemented')

  ###*
  # Called when current profile has changed.
  # In base class, this method is not implemented and will not do anything.
  ###
  currentProfileChanged: -> null

  ###*
  # Set or disable the quick switch profiles.
  # In base class, this method is not implemented and will not do anything.
  # @param {string[]|null} quickSwitch The profile names, or null to disable
  # @returns {Promise} A promise which is fulfilled when the quick switch is set
  ###
  setQuickSwitch: (quickSwitch) ->
    Promise.resolve()

  ###*
  # Schedule a task that runs every periodInMinutes.
  # In base class, this method is not implemented and will not do anything.
  # @param {string} name The name of the schedule. If there is a previous
  # schedule with the same name, it will be replaced by the new one.
  # @param {number} periodInMinutes The interval of the schedule
  # @param {function} callback The callback to call when the task runs
  # @returns {Promise} A promise which is fulfilled when the schedule is set
  ###
  schedule: (name, periodInMinutes, callback) ->
    Promise.resolve()

  ###*
  # Return true if the match result of current profile does not change with URLs
  # @returns {bool} Whether @match always return the same result for requests
  ###
  isCurrentProfileStatic: ->
    return true if not @_currentProfileName
    return false if @_tempProfile
    currentProfile = @currentProfile()
    return false if OmegaPac.Profiles.isInclusive(currentProfile)
    return true

  ###*
  # Update the profile by name.
  # @param {(string|string[]|null)} name The name of the profiles,
  # or null for all.
  # @param {?bool} opt_bypass_cache Do not read from the cache if true
  # @returns {Promise<Object.<string,({}|Error)>>} A map from keys to updated
  # profiles or errors.
  # A value is an error if `value instanceof Error`. Otherwise the value is an
  # updated profile.
  ###
  updateProfile: (name, opt_bypass_cache) ->
    @log.method('Options#updateProfile', this, arguments)
    results = {}
    OmegaPac.Profiles.each @_options, (key, profile) =>
      return if name? and profile.name != name
      url = OmegaPac.Profiles.updateUrl(profile)
      if url
        results[key] = @fetchUrl(url, opt_bypass_cache).then((data) =>
          profile = OmegaPac.Profiles.byKey(key, @_options)
          OmegaPac.Profiles.update(profile, data)
          changes = {}
          changes[key] = profile
          @_setOptions(changes).return(profile)
        ).catch (reason) ->
          if reason instanceof Error then reason else new Error(reason)

    Promise.props(results)

  ###*
  # Make an HTTP GET request to fetch the content of the url.
  # In base class, this method is not implemented and will always reject.
  # @param {string} url The name of the profiles,
  # @param {?bool} opt_bypass_cache Do not read from the cache if true
  # @returns {Promise<String>} The text content fetched from the url
  ###
  fetchUrl: (url, opt_bypass_cache) ->
    Promise.reject new Error('not implemented')

  ###*
  # Rename a profile and update references and options
  # @param {String} fromName The original profile name
  # @param {String} toname The target profile name
  # @returns {Promise<OmegaOptions>} The updated options
  ###
  renameProfile: (fromName, toName) ->
    @log.method('Options#renameProfile', this, arguments)
    if OmegaPac.Profiles.byName(toName, @_options)
      return Promise.reject new Error("Target name #{name} already taken!")
    profile = OmegaPac.Profiles.byName(fromName, @_options)
    if not profile
      return Promise.reject new ProfileNotExistError(name)

    profile.name = toName
    changes = {}
    changes[OmegaPac.Profiles.nameAsKey(profile)] = profile

    OmegaPac.Profiles.each @_options, (key, p) ->
      if OmegaPac.Profiles.replaceRef(p, fromName, toName)
        OmegaPac.Profiles.updateRevision(p)
        changes[OmegaPac.Profiles.nameAsKey(p)] = p

    if @_options['-startupProfileName'] == fromName
      changes['-startupProfileName'] = toName
    quickSwitch = @_options['-quickSwitchProfiles']
    for i in [0...quickSwitch.length]
      if quickSwitch[i] == fromName
        quickSwitch[i] = toName
        changes['-quickSwitchProfiles'] = quickSwitch

    for own key, value of changes
      @_options[key] = value

    fromKey = OmegaPac.Profiles.nameAsKey(fromName)
    changes[fromKey] = undefined
    delete @_options[fromKey]

    if @_watchingProfiles[fromKey]
      if @_currentProfileName == fromName
        @_currentProfileName = toName
      @applyProfile(@_currentProfileName)

    @_setOptions(changes)

  ###*
  # Add a temp rule.
  # @param {String} domain The domain for the temp rule.
  # @param {String} profileName The profile to apply for the domain.
  # @returns {Promise} A promise which is fulfilled when the rule is applied.
  ###
  addTempRule: (domain, profileName) ->
    @log.method('Options#addTempRule', this, arguments)
    return Profile.resolve() if not @_currentProfileName
    profile = OmegaPac.Profiles.byName(profileName, @_options)
    if not profile
      return Promise.reject new ProfileNotExistError(profileName)
    if not @_tempProfile?
      @_tempProfile = OmegaPac.Profiles.create('', 'SwitchProfile')
      currentProfile = @currentProfile()
      @_tempProfile.color = currentProfile.color
      @_tempProfile.defaultProfileName = currentProfile.name
    
    changed = false
    rule = @_tempProfileRules[domain]
    if rule and rule.profileName
      if rule.profileName != profileName
        key = OmegaPac.Profiles.nameAsKey(rule.profileName)
        list = @_tempProfileRulesByProfile[key]
        list.splice(list.indexOf(rule), 1)

        rule.profileName = profileName
        changed = true
    else
      rule =
        condition:
          conditionType: 'HostWildcardCondition'
          pattern: '*.' + domain
        profileName: profileName
        isTempRule: true
      @_tempProfile.rules.push(rule)
      @_tempProfileRules[domain] = rule
      changed = true

    key = OmegaPac.Profiles.nameAsKey(profileName)
    rulesByProfile = @_tempProfileRulesByProfile[key]
    if not rulesByProfile?
      rulesByProfile = @_tempProfileRulesByProfile[key] = []
    rulesByProfile.push(rule)

    if changed
      OmegaPac.Profiles.updateRevision(@_tempProfile)
      @applyProfile(@_currentProfileName)
    else
      Promise.resolve()

  ###*
  # Find a temp rule by domain.
  # @param {String} domain The domain of the temp rule.
  # @returns {Promise<?String>} The profile name for the domain, or null if such
  # rule does not exist.
  ###
  queryTempRule: (domain) ->
    rule = @_tempProfileRules[domain]
    if rule
      if rule.profileName
        return rule.profileName
      else
        delete @_tempProfileRules[domain]
    return null

  ###*
  # Add a condition to the current active switch profile.
  # @param {Object.<String,{}>} cond The condition to add
  # @param {string>} profileName The name of the profile to add the rule to.
  # @returns {Promise} A promise which is fulfilled when the condition is saved.
  ###
  addCondition: (condition, profileName) ->
    @log.method('Options#addCondition', this, arguments)
    return Profile.resolve() if not @_currentProfileName
    profile = OmegaPac.Profiles.byName(@_currentProfileName, @_options)
    if not profile?.rules?
      return Promise.reject new Error(
        "Cannot add condition to Profile #{@profile.name} (@{profile.type})")
    # Try to remove rules with the same condition first.
    tag = OmegaPac.Conditions.tag(condition)
    for i in [0...profile.rules.length]
      if OmegaPac.Conditions.tag(profile.rules[i].condition) == tag
        profile.rules.splice(i, 1)
        break

    # Add the new rule to the beginning so that it won't be shadowed by others.
    profile.rules.unshift({
      condition: condition
      profileName: profileName
    })
    OmegaPac.Profiles.updateRevision(profile)
    changes = {}
    changes[OmegaPac.Profiles.nameAsKey(profile)] = profile
    @_setOptions(changes)

  ###*
  # Add a profile to the options
  # @param {{}} profile The profile to create
  # @returns {Promise<{}>} The saved profile
  ###
  addProfile: (profile) ->
    @log.method('Options#addProfile', this, arguments)
    if OmegaPac.Profiles.byName(profile.name, @_options)
      return Promise.reject(
        new Error("Target name #{profile.name} already taken!"))
    else
      changes = {}
      changes[OmegaPac.Profiles.nameAsKey(profile)] = profile
      @_setOptions(changes)

  ###*
  # Get the matching results of a request
  # @param {{}} request The request to test
  # @returns {Promise<{profile: {}, results: {}[]}>} The last matched profile
  # and the matching details
  ###
  matchProfile: (request) ->
    if not @_currentProfileName
      return Profile.resolve({profile: @_externalProfile, results: []})
    results = []
    profile = @_tempProfile
    profile ?= OmegaPac.Profiles.byName(@_currentProfileName, @_options)
    while profile
      lastProfile = profile
      result = OmegaPac.Profiles.match(profile, request)
      break unless result?
      results.push(result)
      if Array.isArray(result)
        next = result[0]
      else if result.profileName
        next = OmegaPac.Profiles.nameAsKey(result.profileName)
      else
        break
      profile = OmegaPac.Profiles.byKey(next, @_options)
    Promise.resolve(profile: lastProfile, results: results)

  ###*
  # Notify Options that the proxy settings are set externally.
  # @param {{}} profile The external profile
  # @param {?{}} args Extra arguments
  # @param {boolean=false} args.noRevert If true, do not revert changes.
  # @returns {Promise} A promise which is fulfilled when the profile is set
  ###
  setExternalProfile: (profile, args) ->
    if not args?.noRevert and @_options['-revertProxyChanges']
      if profile.name != @_currentProfileName and @_currentProfileName
        if not @_isSystem
          @applyProfile(@_currentProfileName)
          return
    p = OmegaPac.Profiles.byName(profile.name, @_options)
    if p
      @applyProfile(p.name,
        {proxy: false, system: @_isSystem, reason: 'external'})
    else
      @_currentProfileName = null
      @_externalProfile = profile
      profile.color ?= '#49afcd'
      @_state.set({
        'currentProfileName': ''
        'externalProfile': profile
        'validResultProfiles': []
        'currentProfileCanAddRule': false
      })
      @currentProfileChanged('external')
      return

module.exports = Options