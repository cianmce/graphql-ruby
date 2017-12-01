# frozen_string_literal: true
require "graphql/language_server/completion_suggestion/state_machine"
require "graphql/language_server/completion_suggestion/fragment_def"
require "graphql/language_server/completion_suggestion/fragment_spread"
require "graphql/language_server/completion_suggestion/variable_def"
require "graphql/language_server/completion_suggestion/language_scope"

module GraphQL
  class LanguageServer
    # This class responds with an array of `Item`s, based on
    # the cursor's `line` and `column` in `text` of `filename`.
    #
    # `server` has the system info, so it's provided here too.
    class CompletionSuggestion
      def initialize(filename:, text:, line:, column:, server:)
        @text = text
        @line = line
        @filename = filename
        @column = column
        @server = server
        @logger = server.logger
      end

      def items
        completion_items = []
        language_scope = LanguageScope.new(
          filename: @filename,
          text: @text,
          line: @line,
          column: @column,
          logger: @logger,
        )
        if !language_scope.graphql_code?
          @logger.info("Out-of-scope cursor")
          return completion_items
        end
        tokens = GraphQL.scan(@text)
        self_stack = SelfStack.new
        self_stack.stage(@server.type(:query))
        input_stack = InputStack.new
        var_def_state = VariableDef.new(logger: @logger)
        fragment_def_state = FragmentDef.new(logger: @logger)
        fragment_spread_state = FragmentSpread.new(logger: @logger)

        cursor_token = nil
        # statefully work through the tokens, track self_state,
        # and record the cursor token
        tokens.each do |token|
          @logger.info("Token: #{token.inspect}")
          # Allow the state machines to consume this token:
          fragment_def_state.consume(token)
          fragment_spread_state.consume(token)
          var_def_state.consume(token)
          case token.name
          when :QUERY, :MUTATION, :SUBSCRIPTION
            key = token.name.to_s.downcase.to_sym
            self_stack.stage(@server.type(key))
          when :LCURLY
            self_stack.push_staged
            input_stack.push_staged
          when :RCURLY
            self_stack.pop
            input_stack.pop
          when :LPAREN
            self_stack.lock
            input_stack.push_staged
          when :RPAREN
            self_stack.unlock
            input_stack.pop
          when :IDENTIFIER
            self_type = self_stack.last
            input_type = input_stack.last
            @logger.debug("#{token.value} ?? (#{self_type&.name}, #{input_type&.name})")
            if self_type && (field = self_type.get_field(token.value))
              return_type_name = field.type.unwrap.name
              self_stack.stage(@server.type(return_type_name))
              field = self_type.fields[token.value]
              input_stack.stage(field)
            elsif input_type && (argument = input_type.arguments[token.value])
              input_type_name = argument.type.unwrap.name
              input_stack.stage(@server.type(input_type_name))
            elsif fragment_def_state.state == :type_name && (frag_type = @server.type(token.value))
              self_stack.stage(frag_type)
            end
          end

          # Check if this is the cursor_token
          if token.line == @line && ((token.col == @column) || ((token.col < @column) && (token.value.length > 0) && ((token.col + token.value.length) > @column)))
            @logger.info("Found cursor (#{@line},#{@line}): #{token.value}")
            cursor_token = token
            break
          elsif token.line >= @line && token.col > @column
            @logger.info("NO CURSOR TOKEN")
            break
          end
        end

        self_type = self_stack.last
        input_type = input_stack.last
        token_filter = TokenFilter.new(cursor_token)
        @logger.info("Lasts: #{self_type.inspect}, #{input_type.inspect}")
        @logger.info("States: #{var_def_state.state.inspect}, #{fragment_def_state.state.inspect}, #{fragment_spread_state.state.inspect}")
        if cursor_token && @@scalar_tokens.include?(cursor_token.name)
          # The cursor is in the middle of a String or other literal;
          # don't provide autocompletes here because it's not GraphQL code
        elsif var_def_state.state == :type_name
          # We're typing the type of a query variable;
          # Suggest input types that match the current token
          @server.input_type_names.each do |input_type_name|
            if token_filter.match?(input_type_name)
              type = @server.type(input_type_name)
              completion_items << Item.from_type(type: type)
            end
          end
        elsif fragment_spread_state.state == :type_name || fragment_spread_state.state == :on
          # We're typing an inline fragment condition, suggest valid fragment types
          # which overlap with `self_type`
          @server.fields_type_names.each do |fragment_type_name|
            type = @server.type(fragment_type_name)
            if self_type.nil? || GraphQL::Execution::Typecast.subtype?(self_type, type) || GraphQL::Execution::Typecast.subtype?(type, self_type)
              if fragment_spread_state.state == :on || token_filter.match?(fragment_type_name)
                completion_items << Item.from_type(type: type)
              end
            end
          end
        elsif fragment_def_state.state == :type_name || fragment_def_state.state == :on
          # We're typing a fragment condition, suggestion valid fragment types
          @server.fields_type_names.each do |fragment_type_name|
            if fragment_def_state.state == :on || token_filter.match?(fragment_type_name)
              type = @server.type(fragment_type_name)
              completion_items << Item.from_type(type: type)
            end
          end
        elsif var_def_state.ended? && (var_def_state.state == :var_sign || var_def_state.state == :var_name)
          # We're typing a variable usage in the query body,
          # make recommendations based on variables defined above.
          # TODO also filter var defs by type, only suggest vars that match the current field
          var_def_state.defined_variables.each do |var_name|
            if token_filter.value == "$" || token_filter.match?(var_name)
              type = var_def_state.defined_variable_types[var_name]
              completion_items << Item.from_variable(name: var_name, type: type)
            end
          end
        elsif input_type
          # We're typing an argument, suggest argument names on this field/input obj
          # TODO remove argument names that were already used
          all_args = input_type.arguments
          all_args.each do |name, arg|
            completion_items << Item.from_argument(argument: arg)
          end
        elsif self_type.nil? && !self_stack.locked?
          # We're at the root level; make root suggestions
          [:query, :mutation, :subscription].each do |t|
            if (type = @server.type(t))
              label = t.to_s
              if token_filter.match?(label)
                completion_items << Item.from_root(root_type: type)
              end
            end
          end
          if token_filter.match?("fragment")
            completion_items << Item.from_fragment_token
          end
        elsif self_type
          # We're writing fields; suggest fields on the current `self`
          self_type.fields.each do |name, f|
            if token_filter.match?(name)
              completion_items << Item.from_field(owner: self_type, field: f)
            end
          end
        end

        completion_items
      end

      private

      class Item
        attr_reader :label, :detail, :documentation, :kind, :insert_text

        def initialize(label:, detail:, insert_text: nil, documentation:, kind:)
          @label = label
          @detail = detail
          @insert_text = insert_text
          @documentation = documentation
          @kind = kind
        end

        def self.from_field(owner:, field:)
          self.new(
            label: field.name,
            detail: "#{owner.name}.#{field.name}",
            documentation: "#{field.description} (#{field.type.to_s})",
            kind: LSP::Constant::CompletionItemKind::FIELD,
          )
        end

        def self.from_fragment_token
          self.new(
            label: "fragment",
            detail: nil,
            documentation: "Add a new typed fragment",
            kind: LSP::Constant::CompletionItemKind::KEYWORD,
          )
        end

        def self.from_root(root_type:)
          self.new(
            label: root_type.name.downcase,
            detail: "#{root_type.name}!",
            documentation: root_type.description,
            kind: LSP::Constant::CompletionItemKind::KEYWORD,
          )
        end

        def self.from_argument(argument:)
          self.new(
            label: argument.name,
            insert_text: "#{argument.name}:",
            detail: argument.type.to_s,
            documentation: argument.description,
            kind: LSP::Constant::CompletionItemKind::FIELD,
          )
        end

        def self.from_variable(name:, type:)
          # TODO: list & non-null wrappers here
          # TODO include default values as documentation
          self.new(
            label: "$#{name}",
            insert_text: name,
            detail: type,
            documentation: "query variable",
            kind: LSP::Constant::CompletionItemKind::VARIABLE,
          )
        end

        def self.from_type(type:)
          self.new(
            label: type.name,
            detail: type.name,
            documentation: type.description,
            kind: LSP::Constant::CompletionItemKind::CLASS,
          )
        end
      end

      # Use a class variable to avoid warnings when reloading
      @@scalar_tokens = [:STRING, :FLOAT, :INT, :TRUE, :FALSE, :NULL]

      class SelfStack
        def initialize
          @stack = []
          @next_self = nil
        end

        def stage(next_self)
          if !@locked
            @next_self = next_self
          end
        end

        def push_staged
          if !@locked
            push_self(@next_self)
            @next_self = nil
          end
        end

        # Use this when you enter an invalid scope,
        # namely, inside `(...)`, self_stack should be locked.
        def lock
          @locked = true
        end

        def unlock
          @locked = false
        end

        def locked?
          @locked
        end

        def pop
          if !@locked
            @stack.pop
          end
        end

        def last
          if @locked
            nil
          else
            @stack.last
          end
        end

        def empty?
          @stack.none?
        end

        private

        def push_self(next_self)
          @stack << next_self
        end
      end

      class InputStack < SelfStack
      end

      class TokenFilter
        # @return [String, nil]
        attr_reader :value
        # @param token [nil, GraphQL::Language::Token]
        def initialize(token)
          @token = token
          @value = token && token.value
          @uniq_chars = token && token.value.split.uniq
        end

        # @return [Boolean] true if this label matches the token
        def match?(label)
          @token.nil? || @uniq_chars.all? { |c| label.include?(c) }
        end
      end
    end
  end
end
