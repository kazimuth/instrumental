# For transforming the AST.
falafel = require 'falafel'
# For storing copies of the state.
deepcopy = require 'deepcopy'

# Things that happen while we're debugging a program.
class DebugEvent
    # @loc: the original location of the event in the source
    constructor: (@range) ->

    # Visit a state and apply ourselves.
    applyTo: (state) ->
        return

# Something has its value changed.
class AssignmentEvent extends DebugEvent
    constructor: (@range, @variable, @value) ->
    
    # We just set the variable containing the state to a value.
    applyTo: (state) ->
        state[@variable] = @value
        return

# Several things have happened at the same time
class EventList extends DebugEvent
    constructor: (@range, @events) ->

    applyTo: (state) ->
        for child in @events
            child.applyTo state
        return

# Where the magic happens.
# Encapsulates a running program and exposes a few debugging methods, pretty simple.
exports.Debugger = class Debugger
    constructor: (@src, @options = {snapshotFrequency: 30, logCallback: console.log}) ->
        # We transform the source from a short program into a generator that
        # yields a value at every breakpoint. See: 
        # developer.mozilla.org/en-US/docs/Mozilla/Projects/SpiderMonkey/Parser_API
        
        genTempIndex = (string) ->
            path = string.replace(/"/g, "'")
            "\"#{path}\""

        generatorSource = falafel @src, {ranges: true}, (node) ->
            switch node.type
                when 'Program'
                    # Root node! Surround code in a generator.
                    # Takes the various event classes as arguments.
                    # (Have to declare a named generator because node doesn't
                    # like anonymous generators for some reason.)
                    node.update('function* $$debugGenerator($$events){var $$debug={};' + node.source() + '}');
                
                when 'AssignmentExpression'
                    # Assignment expressions:
                    # x = 1
                    # string += 'bananas'
                    # index %= length
                    # We can use parentheses, the comma operator, and the fact that "yield"
                    # is an expression to transform these to:
                    # (
                    #   $$debug.x = (1),
                    #   yield new $$events.AssignmentEvent([0, 4], "x", $$debug.x),
                    #   x = $$debug.x
                    # )
                    # or
                    # (
                    #   $$debug.string = string + ("bananas"),
                    #   yield new $$events.AssignmentEvent([6, 24], "string", $$debug.string),
                    #   string = $$debug.string
                    # )
                    # &c.
                    #
                    
                    name = node.left.source().replace(/"/g, "'")
                    index = genTempIndex name
                    value = node.right.source()
                    
                    if node.operator == '='
                        node.update(
                            "($$debug[#{index}]=(#{value}),
                            yield new $$events.AssignmentEvent([#{node.start}, #{node.end}],\"#{name}\",$$debug[#{index}]),
                            #{name}=$$debug[#{index}])"
                        )
                    else
                        # We want to get '+', '-', '>>>' from '+=', '-=', '>>>='
                        operator = node.operator.slice(0, node.operator.length - 1)
                        node.update(
                            "($$debug[#{index}]=#{name}#{operator}(#{value}),
                            yield new $$events.AssignmentEvent([#{node.start}, #{node.end}],\"#{name}\",$$debug[#{index}]),
                            #{name}=$$debug[#{index}])"
                        )

                when 'VariableDeclarator'
                    # A variable declarator is the part of a 'var' statement that actually assigns things.
                    # We translate:
                    # var z=20, x;
                    # to:
                    # var z=($$debug.z = (20), yield new $$events.AssignmentEvent([FIXME loc], "z", $$debug.z), $$debug.z),
                    #     x=(yield new $$events.AssignmentEvent([FIXME loc], "x", undefined), undefined);
                    name = node.id.source()
                    index = genTempIndex name
                    if node.init
                        value = node.init.source()
                        node.update(
                            "#{name}=($$debug[#{index}]=(#{value}),yield new $$events.AssignmentEvent([#{node.start}, #{node.end}],\"#{name}\",$$debug[#{index}]),$$debug[#{index}])"
                        )
                    else
                        # No initializer
                        node.update(
                            "#{name}=(yield new $$events.AssignmentEvent([#{node.start}, #{node.end}],\"#{name}\",undefined),undefined)"
                        )

                when 'UpdateExpression'
                    # x++, --z
                    name = node.argument.source().replace(/"/g, "'")
                    index = genTempIndex name
                    operator = node.operator
                    if node.prefix
                        # prefix operator: gives value _after_ modifying object
                        # Node: use actual operator because x+=1 has /slightly/ different semantics from ++x, I think
                        node.update(
                            "(#{operator}#{name},yield new $$events.AssignmentEvent([#{node.start}, #{node.end}],\"#{name}\",#{name}),#{name})"
                        )
                    else
                        # postfix: give value from _before_ modifying object
                        node.update(
                            "($$debug[#{index}]=#{name},#{name}#{operator}, yield new $$events.AssignmentEvent([#{node.start}, #{node.end}],\"#{name}\",#{name}),$$debug[#{index}])"
                        )

                when 'CallExpression'
                    # This is an interesting bag of worms.
                    # We want to descend into called functions. How can we possibly do that with iterators?
                    # With yield*!
                    # First, whenever we run into a user function, we make it into 
                    #
                    # var bananas = bananaCount(args);
                    #
                    # is transformed into
                    #
                    # var bananas = ($$debug.fn$14 = (bananaCount),
                    #                $$debug.fn$14.constructor.name === 'GeneratorFunction' ?
                    #                   ($$debug.fn$14$retHack = {},
                    #                    yield* $$debug.fn$14(args),
                    #                    $$debugfn$14$retHack.value)
                    #                    :
                    #                   $$debug['bananaCount'](args));
                    #

        # Create the iterator we use to run the code
        @processedSource = generatorSource.toString()
        eval @processedSource
        @generator = $$debugGenerator
        @iterator = @generator {AssignmentEvent:AssignmentEvent, EventList:EventList}

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

    step: ->
        # Step forward
        @eventIndex++
        if @eventIndex < @events.length
            # We're just redoing stuff we've already seen
            @events[@eventIndex].applyTo @currentState
        else
            # We're running the code!
            if @completed
                # ...unless we're not.
                @eventIndex--
                return

            # THE ONLY PLACE where @iterator is actually iterated.
            result = @iterator.next()

            if result.done
                # Iterator has completed, no event this time.
                @completed = true
                @eventIndex--
                return

            event = result.value
            @events.push event
            event.applyTo @currentState
            if event instanceof AssignmentEvent
                @options.logCallback "#{event.variable} = #{JSON.stringify event.value};"

            # Check if we should take a snapshot.
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
            @events[@eventIndex].applyTo @currentState

    activeRange: ->
        if @completed
            [0,0]
        else
            @events[@eventIndex].range
