# For transforming the AST.
falafel = require 'falafel'
# For storing copies of the CallStack.
deepcopy = require 'deepcopy'

# Things that happen while we're debugging a program.
class DebugEvent
    # @loc: the original location of the event in the source
    constructor: (@range) ->

    # Visit a CallStack and apply ourselves.
    applyTo: (callStack) ->
        return

    log: (logCallback) ->

# Something has its value changed.
# TODO treat variables as key-paths instead of strings
class AssignmentEvent extends DebugEvent
    constructor: (@range, @variable, @value, @initialize) ->
    
    # Scoping!
    applyTo: (callStack) ->
        if @initialize
            # Part of a "var" statement, set in top scope.
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
        logCallback "Assignment: #{@variable} = #{JSON.stringify @value};"
        return

# Ifs, whiles, and fors.
class BooleanCheckEvent extends DebugEvent
    constructor: (@range, @value) ->

    log: (logCallback) ->
        logCallback "Truth check: #{JSON.stringify @value}"
        return

# Called for expression statements.
class ExpressionEvent extends DebugEvent
    constructor: (@range, @value) ->

    log: (logCallback) ->
        if @value != undefined
            logCallback "Expression: #{JSON.stringify @value}"
        return

# Called before entering a function.
class FunctionEntry extends DebugEvent
    constructor: (@range, @name) ->
    
    # Add a namespace to the top of the call stack.
    applyTo: (callStack) ->
        callStack.push {}
        return

    log: (logCallback) ->
        logCallback "Entered function: #{@name}"
        return

# Called when leaving a function.
class FunctionExit extends DebugEvent
    constructor: (@range, @value) ->

    # Remove the top layer of the call stack.
    applyTo: (callStack) ->
        if callStack.length < 1
            throw "Tracking callstack is empty, everything is broken"
        callStack.pop()
        return

    log: (logCallback) ->
        logCallback "Returned: #{@value}"
        return


# Several things have happened at the same time
class EventList extends DebugEvent
    constructor: (@range, @events) ->

    applyTo: (CallStack) ->
        for child in @events
            child.applyTo CallStack
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
                    
                    name = node.left.source().replace(/"/g, "'")
                    index = genTempIndex name
                    value = node.right.source()
                    
                    if node.operator == '='
                        node.update(
                            "($$debug[#{index}]=(#{value}),
                            yield new $$events.AssignmentEvent([#{node.start}, #{node.end}],\"#{name}\",$$debug[#{index}],false),
                            #{name}=$$debug[#{index}])"
                        )
                    else
                        # We want to get '+', '-', '>>>' from '+=', '-=', '>>>='
                        operator = node.operator.slice(0, node.operator.length - 1)
                        node.update(
                            "($$debug[#{index}]=#{name}#{operator}(#{value}),
                             yield new $$events.AssignmentEvent(
                                 [#{node.start}, #{node.end}],
                                 \"#{name}\",
                                 $$debug[#{index}],
                                 false),
                             #{name}=$$debug[#{index}])"
                        )

                when 'VariableDeclarator'
                    # A variable declarator is the part of a 'var' statement that actually assigns things.
                    # We translate:
                    # var z=20, x;
                    # to:
                    # var z=($$debug.z = (20), yield new $$events.AssignmentEvent([4, 7], "z", $$debug.z), $$debug.z, true),
                    #     x=(yield new $$events.AssignmentEvent([10, 11], "x", undefined, true), undefined);
                    name = node.id.source()
                    index = genTempIndex name
                    if node.init
                        value = node.init.source()
                        node.update(
                            "#{name}=($$debug[#{index}]=(#{value}),
                                      yield new $$events.AssignmentEvent(
                                          [#{node.start}, #{node.end}],
                                          \"#{name}\",
                                          $$debug[#{index}],
                                          true),
                                      $$debug[#{index}])"
                        )
                    else
                        # No initializer
                        node.update(
                            "#{name}=(yield new $$events.AssignmentEvent(
                                          [#{node.start}, #{node.end}],
                                          \"#{name}\",
                                          undefined,
                                          true),
                                      undefined)"
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
                            "(#{operator}#{name},
                              yield new $$events.AssignmentEvent(
                                  [#{node.start}, #{node.end}],
                                  \"#{name}\",
                                  #{name},
                                  false),
                              #{name})"
                        )
                    else
                        # postfix: give value from _before_ modifying object
                        node.update(
                            "($$debug[#{index}]=#{name},
                              #{name}#{operator},
                              yield new $$events.AssignmentEvent(
                                  [#{node.start}, #{node.end}],
                                  \"#{name}\",
                                  #{name},
                                  false),
                              $$debug[#{index}])"
                        )

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
                # bananaCount = function*(args, $$retHack) {
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
                # var bananas = ($$debug.call$14 = (bananaCount),
                #                $$debug.call$14.constructor.name === 'GeneratorFunction' ?
                #                   ($$debug.call$14$retHack = {},
                #                    yield new $$events.FunctionEntry([14,31], $$debug.call$14.name || '[anonymous]'),
                #                    yield* $$debug.call$14(1, $$debug.call$14.retHack),
                #                    $$debug.call$14$retHack.value)
                #                    :
                #                   $$debug.call$14(1));
                #
                # (Yeah, bit of a mouthful. We have to check if it's a generator at runtime because we can't solve the halting problem.)

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
                         yield new $$events.FunctionExit([#{node.start},#{node.end}],$$retHack.value);
                         return;"
                    )

                when 'CallExpression'
                    name = "call$#{node.range[0]}"
                    retName = name + "$retHack"
                    args = ""
                    for arg in node.arguments
                        args += arg.source() + ','

                    node.update (
                        "($$debug.#{name} = (#{node.callee.source()}),
                          $$debug.#{name}.constructor.name === 'GeneratorFunction' ?
                            ($$debug.#{retName} = {},
                            yield new $$events.FunctionEntry(
                                [#{node.start},#{node.end}],
                                $$debug.#{name}.name || '[anonymous]'),
                            yield* $$debug.#{name}(#{args} $$debug.#{retName}),
                            $$debug.#{retName}.value)
                            :
                            ($$debug.#{name}(#{args[0..-2]})))"
                    )

        # Create the iterator we use to run the code
        @processedSource = generatorSource.toString()
        eval @processedSource
        @generator = $$debugGenerator
        @iterator  = @generator {AssignmentEvent:AssignmentEvent,BooleanCheckEvent:BooleanCheckEvent,ExpressionEvent:ExpressionEvent,FunctionEntry:FunctionEntry,FunctionExit:FunctionExit,EventList:EventList}

        # Tracking state
        # We store a long list of events and apply their changes to the current
        # call stack as we walk through the iterator.
        # (We represent the call stack as an array of dictionaries.)
        @events = []
        @eventIndex = -1
        @currentCallStack = [{}]

        # We step backwards by replaying events that have happened so far.
        # Normally, that would take a long time, but we cheat by storing 
        # snapshots of the CallStack every @options.snapshotFrequency events.
        @savedCallStacks = {}

        # Bookkeeping.
        @completed = false

    step: ->
        # Step forward
        @eventIndex++
        if @eventIndex < @events.length
            @options.logCallback "Applying #{@eventIndex}"
            # We're just redoing stuff we've already seen
            @events[@eventIndex].applyTo @currentCallStack
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
            event.applyTo @currentCallStack
            event.log @options.logCallback

            # Check if we should take a snapshot.
            if @eventIndex % @options.snapshotFrequency == 0
                @savedCallStacks[@eventIndex] = deepcopy(@currentCallStack)
            
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
        if targetEvent <= 0
            targetEvent = 0

        closestEvent = targetEvent - (targetEvent % @options.snapshotFrequency)

        console.log @savedCallStacks

        @currentCallStack = @savedCallStacks[closestEvent]
        @eventIndex = closestEvent
        while @eventIndex < targetEvent and not @completed
            @step()


    activeRange: ->
        if @completed
            [0,0]
        else
            @events[@eventIndex].range
