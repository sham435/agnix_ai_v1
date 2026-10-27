# SafeMath — evaluates simple arithmetic without eval.
# Supports: +, -, *, /, %, parentheses, decimals, unary +/-
# Rejects: method calls, variables, any Ruby code.
class SafeMath
  class Error < StandardError; end

  class << self
    def eval(expression)
      expr = expression.to_s.strip
      raise Error, "Empty expression" if expr.empty?

      tokens = tokenize(expr)
      raise Error, "No valid tokens" if tokens.empty?

      value, pos = parse_expression(tokens, 0)
      raise Error, "Unexpected trailing input" if pos != tokens.length

      value
    end

    private

    def tokenize(expr)
      tokens = []
      i = 0
      while i < expr.length
        char = expr[i]

        if char =~ /\s/
          i += 1
          next
        end

        # Number starting with digit or .digit
        if char =~ /\d/ || (char == "." && i + 1 < expr.length && expr[i + 1] =~ /\d/)
          num = +""
          dot_seen = false
          while i < expr.length && (expr[i] =~ /\d/ || expr[i] == ".")
            if expr[i] == "."
              raise Error, "Invalid number format" if dot_seen
              dot_seen = true
            end
            num << expr[i]
            i += 1
          end
          tokens << [:NUM, num.to_f]
          next
        end

        # Operators
        if "+-*/%".include?(char)
          tokens << [:OP, char.to_sym]
          i += 1
          next
        end

        if char == "("
          tokens << [:LPAREN, "("]
          i += 1
          next
        end

        if char == ")"
          tokens << [:RPAREN, ")"]
          i += 1
          next
        end

        raise Error, "Unexpected character: '#{char}'"
      end
      tokens
    end

    # expression = term (('+' | '-') term)*
    def parse_expression(tokens, pos)
      left, pos = parse_term(tokens, pos)

      while pos < tokens.length && (tokens[pos] == [:OP, :+] || tokens[pos] == [:OP, :-])
        op = tokens[pos][1]
        pos += 1
        right, pos = parse_term(tokens, pos)
        left = op == :+ ? left + right : left - right
      end
      [left, pos]
    end

    # term = factor (('*' | '/' | '%') factor)*
    def parse_term(tokens, pos)
      left, pos = parse_factor(tokens, pos)

      while pos < tokens.length
        break unless tokens[pos][0] == :OP
        op = tokens[pos][1]
        break unless [:*, :/, :%].include?(op)

        pos += 1
        right, pos = parse_factor(tokens, pos)
        left = case op
               when :* then left * right
               when :/
                 raise Error, "Division by zero" if right == 0
                 left.to_f / right.to_f
               when :% then left % right
               end
      end
      [left, pos]
    end

    # factor = ('+' | '-') factor | NUM | '(' expression ')'
    def parse_factor(tokens, pos)
      raise Error, "Unexpected end of expression" if pos >= tokens.length

      type, val = tokens[pos]

      if type == :OP && [:+, :-].include?(val)
        pos += 1
        value, pos = parse_factor(tokens, pos)
        return [val == :- ? -value : value, pos]
      end

      if type == :NUM
        return [val, pos + 1]
      end

      if type == :LPAREN
        pos += 1
        value, pos = parse_expression(tokens, pos)
        raise Error, "Missing closing parenthesis" unless pos < tokens.length && tokens[pos][0] == :RPAREN
        return [value, pos + 1]
      end

      raise Error, "Unexpected token: #{tokens[pos].inspect}"
    end
  end
end
