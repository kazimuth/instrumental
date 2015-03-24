# For transforming the AST.
falafel = require 'falafel'
# For storing copies of the CallStack.
deepcopy = require 'deepcopy'

# stringifying some things is undefined, fall back to [Function] &ct.
debugFormat = (obj) ->
    (JSON.stringify obj) || "[#{obj.constructor.name}]"

# Things that happen while we're debugging a program.
class DebugEvent
    # @range: the original location of the event in the source
    constructor: (@range) ->

    # Visit a call stack and apply ourselves.
    applyTo: (callStack) ->
        return

    # Log something using this callback
    log: (logCallback) ->

# Something has its value changed.
# TODO treat variables as key-paths instead of strings
class AssignmentEvent extends DebugEvent
    # @variable, @value: obvious
    # @initialize: whether this variable is being initialized (as in a "var"
    # statement or a function argument list) or merely assigned.
    constructor: (@range, @variable, @value, @initialize) ->
    
    # Scoping!
    applyTo: (callStack) ->
        if @initialize
            # Part of a "var" statement / a function argument, set in top scope.
            callStack[callStack.length - 1][@variable] = @value
            return
        else
            # Not in a "var" statement, walk down the stack.
            # TODO do something about closures.
            for i in [callStack.length-1..0]
                if callStack[i][@variable] != undefined
                    callStack[i][@variable] = @value
                    return
            callStack[0][@variable] = @value
            return

    log: (logCallback) ->
        logCallback "Assigning: #{@variable} = #{debugFormat @value};" 
        return

# Ifs, whiles, and fors.
class ConditionEvent extends DebugEvent
    constructor: (@range, @test, @value) ->

    log: (logCallback) ->
        logCallback "Condition #{@test}: #{debugFormat @value} 
                     #{ if (!!@value == @value) then "" else "(#{!!@value})" }" # Log truthiness, if necessary
        return

# Called before entering a function.
class InstFuncEntry extends DebugEvent
    constructor: (@range, @name) ->
    
    # Add a namespace to the top of the call stack.
    applyTo: (callStack) ->
        callStack.push {}
        return

    log: (logCallback) ->
        logCallback "Entering function: #{@name}"
        return

# Called when leaving a function.
class InstFuncExit extends DebugEvent
    constructor: (@range, @value) ->

    # Remove the top layer of the call stack.
    applyTo: (callStack) ->
        if callStack.length < 1
            throw "Tracking callstack is empty, everything is broken"
        callStack.pop()
        return

    log: (logCallback) ->
        logCallback "Returning: #{debugFormat @value}"
        return

# For functions that we haven't instrumented.
class FunctionCall extends DebugEvent
    constructor: (@range, @function, @args) ->

    log: (logCallback) ->
        argString = ""
        for arg in @args
            argString += (debugFormat arg) + ', '
        logCallback "Calling #{@function} with arguments (#{argString})"
        return

# When the program finishes.
# n.b. Not yielded from within the program.
class DoneEvent extends DebugEvent
    constructor: () ->
        @range = [0,0]

# Several things at the same time.
class EventList extends DebugEvent
    constructor: (@range, @events) ->

    applyTo: (callStack) ->
        for child in @events
            child.applyTo callStack
        return

    log: (logCallback) ->
        for child in @events
            child.log logCallback

# Where the magic happens.
# Encapsulates a running program and exposes a few debugging methods, outwardly simple.
exports.Debugger = class Debugger
    constructor: (@src, @options = {snapshotFrequency: 30, logCallback: console.log}) ->
        # 'falafel' takes a source string, a set of options, and a callback.
        # It parses the source string into an AST and visits it bottom-up,
        # calling the callback on each ast node.
        # See developer.mozilla.org/en-US/docs/Mozilla/Projects/SpiderMonkey/Parser_API
        # for the specs on the AST nodes.
        # Each node has some extra properties / methods due to falafel; the
        # most important is 'node.update()', which modifies the source of the node with
        # a string. (note that AST nodes created from node.update are NOT visited. I think.)
        # falafel returns the source string, including all modifications.
        # We use this to transform the user code into an ES6-style generator, which
        # yields DebugEvents whenever something interesting happens. We store an iterator
        # created by the generator, call 'next' on it whenever the user steps the debugger,
        # and store the events yielded so we can walk backwards through time.
        generatorSource = falafel @src, {ranges: true}, (node) ->
            # 'ranges' means that every node will have 'start' and 'end' 
            # properties corresponding to their ORIGINAL locations in the source.
            # (We use this for highlighting.)
            switch node.type
                when 'Program'
                    # Root node! Surround code in a generator.
                    # Takes the various event classes as arguments.
                    # (Have to declare a named generator because node doesn't
                    # like anonymous generators for some reason.)
                    node.update("function* $$debugGenerator($$events){var $$debug={};#{node.source()}}");
                
                when 'AssignmentExpression'
                    # Assignment expressions:
                    # x = 1
                    # string += 'bananas'
                    # index %= length
                    # We can use parentheses, the comma operator, and the fact that "yield"
                    # is an expression to transform these to:
                    # (
                    #   $$debug.x = (1),
                    #   yield new $$events.AssignmentEvent([0, 4], "x", $$debug.x, false),
                    #   x = $$debug.x
                    # )
                    # or
                    # (
                    #   $$debug.string = string + ("bananas"),
                    #   yield new $$events.AssignmentEvent([6, 24], "string", $$debug.string, false),
                    #   string = $$debug.string
                    # )
                    # &c.
                    #

                    debugName = "expr$#{node.start}$#{node.end}"
                    variable = node.left.source()
                    value = node.right.source()

                    if node.operator == '='
                        node.update (
                            "($$debug.#{debugName}=(#{value}),
                              yield new $$events.AssignmentEvent(
                                [#{node.start},#{node.end}],
                                \"#{variable.replace(/"/g,"'")}\",
                                $$debug.#{debugName},
                                false),
                              #{variable}=$$debug.#{debugName})"
                        )
                    else
                        # We want to get '+', '-', '>>>' from '+=', '-=', '>>>='
                        operator = node.operator[0..-2]
                        node.update (
                            "($$debug.#{debugName}=#{variable}#{operator}(#{value}),
                              yield new $$events.AssignmentEvent(
                                [#{node.start}, #{node.end}],
                                 \"#{variable.replace(/"/g, "'")}\",
                                 $$debug.#{debugName},
                                 false),
                              #{variable}=$$debug.#{debugName})"
                        )

                when 'VariableDeclarator'
                    # A variable declarator is the part of a 'var' statement that actually assigns things.
                    # We translate:
                    # var z=20, x;
                    # to:
                    # var z=($$debug.var$4$5 = (20), yield new $$events.AssignmentEvent([4, 7], "z", $$debug.var$4$5), $$debug.var$4$5, true),
                    #     x=(yield new $$events.AssignmentEvent([10, 11], "x", undefined, true), undefined);
                    # The last argument to AssignmentEvent is true because 
                    variable = node.id.source()
                    if node.init
                        debugName = "var$#{node.start}$#{node.end}"
                        value = node.init.source()
                        node.update(
                            "#{variable}=($$debug.#{debugName}=(#{value}),
                                      yield new $$events.AssignmentEvent(
                                          [#{node.start}, #{node.end}],
                                          \"#{variable}\",
                                          $$debug.#{debugName},
                                          true),
                                      $$debug.#{debugName})"
                        )
                    else
                        # No initializer
                        node.update(
                            "#{variable}=(yield new $$events.AssignmentEvent(
                                          [#{node.start}, #{node.end}],
                                          \"#{variable}\",
                                          undefined,
                                          true),
                                      undefined)"
                        )

                when 'UpdateExpression'
                    # x++, --z
                    variable = node.argument.source()
                    operator = node.operator
                    if node.prefix
                        # prefix operator: gives value _after_ modifying object
                        # Node: use actual operator because x+=1 has /slightly/ different semantics from ++x
                        node.update(
                            "(#{operator}#{variable},
                              yield new $$events.AssignmentEvent(
                                  [#{node.start}, #{node.end}],
                                  \"#{variable.replace(/"/g,"'")}\",
                                  #{variable},
                                  false),
                              #{variable})"
                        )
                    else
                        # postfix: yield value after modification, return value from before
                        debugName = "expr$#{node.start}$#{node.end}"
                        node.update(
                            "($$debug.#{debugName}=#{variable},
                              #{variable}#{operator},
                              yield new $$events.AssignmentEvent(
                                  [#{node.start}, #{node.end}],
                                  \"#{variable.replace(/"/g,"'")}\",
                                  #{variable},
                                  false),
                              $$debug.#{debugName})"
                        )

                when 'IfStatement', 'ForStatement', 'WhileStatement', 'DoWhileStatement'
                    # if (bananas==17) { stuff; } else things;
                    # is transformed to:
                    # if ($$debug.cond$4$14=(bananas==17),
                    #     yield new $$events.ConditionEvent([0,39],'bananas==17',$$debug.cond$0),
                    #     $$debug.cond$0) { stuff; } else things;
                    #
                    # Similar transformations happen for other conditionals.
                    name = "cond$#{node.test.start}$#{node.test.end}"
                    node.test?.update ( # Node isn't guaranteed to have a 'test' property (e.g. while(){})
                        "$$debug.#{name}=(#{node.test.source()}),
                         yield new $$events.ConditionEvent(
                            [#{node.test.start},#{node.test.end}],
                            \"#{node.test.source().replace(/"/g,"'")}\",
                            $$debug.#{name}),
                         $$debug.#{name}"
                    )

                # Functions!
                # This is an interesting bag of worms.
                # We want to descend into called functions. How can we possibly do that with iterators?
                # With yield*!
                # First, whenever we run into a user function, we make it 
                # into a generator, and use pass-reference-by-value to get
                # a hacky return value:
                #
                # bananaCount = function(n) { ...; return 3; };
                #
                # Becomes:
                #
                # bananaCount = function*(n, $$retHack) {
                #       $$debug = {};
                #       yield new $$events.EventList([new $$events.AssignmentEvents([0,0], "n", 1, true)]);
                #       ...;
                #       $$retHack.value = 3;
                #       return;
                # };
                #
                # Then, we transform calls:
                #
                # var bananas = bananaCount(1);
                #
                # Becomes:
                #
                # var bananas = ($$debug.call$14$27 = (bananaCount), # just in case it's a stateful expression
                #                $$debug.call$14$27.constructor.name === 'GeneratorFunction' ? # is it a generator?
                #                   ($$debug.call$14$27$retHack = {}, # prepare to yield*
                #                    yield new $$events.InstFuncEntry([14,31], $$debug.call$14$27.name || '[anonymous]'),
                #                    yield* $$debug.call$14$27(1, $$debug.call$14$27$retHack), # variables will be logged inside the function
                #                    $$debug.call$14$27$retHack.value)
                #                    :
                #                   ($$debug.arg$25$26 = (1), # capture arguments
                #                    yield new $$events.
                #                   $$debug.call$14$27(1)); # call it normally
                #
                # (Yeah, bit of a mouthful. We have to check if callees are generators at runtime because we can't solve the halting problem.)

                when 'FunctionDeclaration', 'FunctionExpression'
                    body = "var $$debug = {}; yield new $$events.EventList([#{node.start},#{if node.id then node.id.end else node.start + 8}], ["
                    for param in node.params
                        body += "new $$events.AssignmentEvent([0,0], \"#{param.source()}\", #{param.source()}, true),"
                    body = body[0..-2]
                    body += "]);"

                    for statement in node.body.body
                        body += statement.source()

                    params = ""
                    for param in node.params
                        params += param.source() + ','

                    node.update (
                       "function* #{node.id?.source() or ''} (#{params} $$retHack) { #{body} }"
                    )

                when 'ReturnStatement'
                    node.update (
                        "$$retHack.value = #{node.argument.source()};
                         yield new $$events.InstFuncExit([#{node.start},#{node.end}],$$retHack.value);
                         return;"
                    )

                when 'CallExpression'
                    debugName = "call$#{node.start}$#{node.end}"
                    retName = debugName + "$retHack"
                    args = ""
                    for arg in node.arguments
                        args += arg.source() + ','
                    
                    node.update (
                        "($$debug.#{debugName} = (#{node.callee.source()}),
                          $$debug.#{debugName}.constructor.name === 'GeneratorFunction' ?
                            ($$debug.#{retName} = {},
                            yield new $$events.InstFuncEntry(
                                [#{node.start},#{node.end}],
                                $$debug.#{debugName}.name || \"#{node.callee.source().replace(/"/g,"'")}\"),
                            yield* $$debug.#{debugName}(#{args} $$debug.#{retName}),
                            $$debug.#{retName}.value)
                            :
                            ($$debug.#{debugName}(#{args[0..-2]})))"
                    )
        # </falafel>

        # Get the result of the falafel call
        @processedSource = generatorSource.toString()

        console.log @processedSource

        # Run the processed source in an anonymous function, and capture the returned generator
        @generator = ((src)->
            eval src
            $$debugGenerator)(@processedSource)

        # Create an iterator from the generator (which takes the dictionary $$events)
        @iterator  = @generator {
            AssignmentEvent:AssignmentEvent,
            ConditionEvent:ConditionEvent,
            InstFuncEntry:InstFuncEntry,
            InstFuncExit:InstFuncExit,
            FunctionCall:FunctionCall,
            EventList:EventList
        }

        # Tracking state
        # We store a long list of events and apply their changes to the current
        # call stack as we walk through the iterator.
        # (We represent the call stack as an array of dictionaries.)
        # n.b. @events is the event list, $$events is the event class dictionary.
        @events = []
        @eventIndex = -1
        @currentCallStack = [{}]

        # We step backwards by replaying events that have happened so far.
        # Normally, that would take a long time, but we cheat by storing 
        # snapshots of the CallStack every @options.snapshotFrequency events,
        # in this variable
        @savedCallStacks = {}

    # Step forward.
    step: ->
        # First, make sure we're not done.
        return if @atEnd()

        # @eventIndex is the index of the event we're about to apply
        @eventIndex++
        if @eventIndex < @events.length
            # We're just redoing stuff we've already seen.
            @events[@eventIndex].applyTo @currentCallStack
        else
            # @eventIndex == @events.length; we don't have an event for this index yet.

            # Get the event.
            # n.b. THE ONLY PLACE where @iterator is actually iterated.
            result = @iterator.next()

            if result.done
                # Iterator has completed, hasn't yielded a value
                @events.push new DoneEvent()
            else
                # result.value is whatever was 'yield'ed.
                event = result.value
                # Add it to the event list.
                @events.push event
                # Apply the event to the call stack.
                event.applyTo @currentCallStack
                # Log the event (visitor-style).
                event.log @options.logCallback

            # Check if we should take a snapshot.
            if @eventIndex % @options.snapshotFrequency == 0
                @savedCallStacks[@eventIndex] = deepcopy(@currentCallStack)

    # Take multiple steps.
    steps: (n) ->
        return if n <= 0 # Don't get clever.
        targetEventIndex = @eventIndex + n
        while @eventIndex < targetEventIndex and not @atEnd()
            @step()
        return

    # Take a single step back.
    stepBack: ->
        @stepsBack 1
        return

    # Take multiple steps back.
    stepsBack: (n) ->
        return if n <= 0 # Don't bother.

        targetEventIndex = @eventIndex - n
        if targetEventIndex < 0
            targetEventIndex = 0

        # Closest saved event.
        closestEventIndex = targetEventIndex - (targetEventIndex % @options.snapshotFrequency)

        @currentCallStack = @savedCallStacks[closestEventIndex]
        @eventIndex = closestEventIndex
        while @eventIndex < targetEventIndex and not @atEnd()
            @step()
        @options.logCallback "Current event:"
        @events[@eventIndex].log @options.logCallback
        return

    # Check if we're finished.
    atEnd: () ->
        @events[@eventIndex] instanceof DoneEvent

    # Used for hilighting.
    activeRange: ->
        @events[@eventIndex].range
