# For transforming the AST.
falafel = require 'falafel'
# For storing copies of the state.
deepcopy = require 'deepcopy'

# Things that happen while we're debugging a program
class DebugEvent
    constructor: (@loc) ->

class AssignmentEvent extends DebugEvent
    constructor: (@loc, @var, @value) ->

class EventList extends DebugEvent
    constructor: (@events) ->

# Where the magic happens.
# Encapsulates a running program and exposes a few 
exports.Debugger = class Debugger
    constructor: (@src, @options = {snapshotFrequency: 30, verbose: true}) ->
        # We transform the source from a short program into a generator that
        # yields a value at every breakpoint. See: 
        # developer.mozilla.org/en-US/docs/Mozilla/Projects/SpiderMonkey/Parser_API
        generatorSource = falafel @src, {locations: true}, (node) ->
            switch node.type
                when 'Program'
                    # Root node! Surround code in a generator.
                    # Takes the various event classes as arguments.
                    # Have to declare a local variable because node doesn't
                    # like anonymous generators for some reason.
                    node.update('function* debugGenerator(AssignmentEvent, EventList){' + node.source() + '}');

                when 'ExpressionStatement'
                    # only handle top-level assignments, for now
                    # (no using assignments as expressions!)
                    if node.expression.type == 'AssignmentExpression'
                        binding = node.expression.left
                        # Totally how hygiene works:
                        mangledName = "#{binding.name}$$#{binding.start}"
                        value = node.expression.right.source()
                        node.update(
                            "var #{mangledName} = #{value};
                            #{binding.name} = #{mangledName};
                            yield new AssignmentEvent(0, \"#{binding.name}\", #{mangledName});"
                        )

                when 'VariableDeclaration'
                    vars = []
                    for decl in node.declarations
                        name = decl.id.name
                        vars.push({
                            name:       name,
                            mangled:    "#{name}$$#{decl.start}",
                            value:      decl.init?.source()
                        })

                    result = ''
                    for v in vars
                        if v.value
                            result += "var #{v.mangled} = #{v.value};"

                    result += 'var '
                    for v, i in vars
                        result += v.name
                        if i < vars.length - 1
                            result += ','

                    result += ';'
                    for v in vars
                        if v.value
                            result += "#{v.name} = #{v.mangled};"

                    result += 'yield new EventList(['
                    for v, i in vars
                        if v.value
                            result += "new AssignmentEvent(0, \"#{v.name}\", #{v.mangled})"
                        else
                            result += "new AssignmentEvent(0, \"#{v.name}\", undefined)"
                        if i < vars.length - 1
                            result += ','

                    result += ']);'
                    node.update(result)

        # Create the iterator we use to run the code
        @processedSource = generatorSource.toString()
        eval @processedSource
        @generator = debugGenerator
        @iterator = @generator(AssignmentEvent, EventList)

        # Tracking states
        # We store a long list of events and apply their changes to the current
        # state as we walk through the iterator.
        @events = []
        @eventIndex = -1
        @currentState = {}

        # We step backwards by replaying events that have happened so far.
        # Normally, that would take a long time, but we cheat by storing 
        # snapshots of the state every @options.snapshotFrequency events.
        @savedStates = {}

        # Bookkeeping.
        @completed = false

    applyEvent: (event, state) ->
        if event instanceof AssignmentEvent
            @currentState[event.var] = event.value
            console.log "Assignment: #{event.var} = #{event.value}"
        else if event instanceof EventList
            for child in event.events
                @applyEvent child

    step: ->
        # Step forward
        @eventIndex++
        if @eventIndex < @events.length
            # We're just redoing stuff we've already seen
            @applyEvent @events[@eventIndex]
        else
            # We're running the code!
            if @completed
                # ...unless we're not.
                @eventIndex--
                return
            result = @iterator.next()
            if result.done
                @completed = true
                @eventIndex--
                return

            @events.push result.value
            @applyEvent result.value

            if @eventIndex % @options.snapshotFrequency == 0
                @savedStates[@eventIndex] = deepcopy(@currentState)
            
            return

    steps: (n) ->
        targetEvent = @eventIndex + n
        while @eventIndex < targetEvent and not @completed
            @step()

    stepBack: ->
        @stepsBack 1

    stepsBack: (n) ->
        return if n == 0
        targetEvent = @eventIndex - n
        if targetEvent < 0
            @eventIndex = -1
            @currentState = {}
            return

        closestEvent = targetEvent - (targetEvent % @options.snapshotFrequency)

        @currentState = @savedStates[closestEvent]
        @eventIndex = closestEvent
        while @eventIndex < targetEvent
            @eventIndex++
            @applyEvent @events[@eventIndex]
        #    console.log "index", @eventIndex

