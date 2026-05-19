defmodule Gas.VariableTest do
  use ExUnit.Case, async: true
  alias Gas.Variable
  alias Gas.Parser.Loc

  @loc %Loc{line: 1, column: 1}

  defp parse(template) do
    context = %Gas.ParserContext{rest: "{{#{template}}}", line: 1, column: 1, mode: :normal}
    {:ok, tokens, _context} = Gas.Lexer.tokenize_object(context)

    Variable.parse(tokens)
  end

  describe "to_string/1" do
    test "variable with accesses" do
      var = %Gas.Variable{
        identifier: "var1",
        original_name: "var1[var2[\"var3\"]][\"var4\"]",
        accesses: [
          %Gas.AccessVariable{
            loc: %Loc{column: 8, line: 1},
            variable: %Gas.Variable{
              original_name: "var2[\"var3\"]",
              loc: %Loc{column: 8, line: 1},
              identifier: "var2",
              accesses: [
                %Gas.AccessLiteral{loc: %Loc{column: 13, line: 1}, value: "var3"}
              ]
            }
          },
          %Gas.AccessLiteral{
            loc: %Loc{column: 19, line: 1},
            value: "var4"
          }
        ],
        loc: %Loc{column: 3, line: 1}
      }

      assert to_string(var) == "var1[var2[\"var3\"]][\"var4\"]"
    end
  end

  describe "static_keys/1" do
    test "returns nil for empty accesses" do
      var = %Variable{loc: @loc, identifier: "x", accesses: [], original_name: "x"}
      assert Variable.static_keys(var) == nil
    end

    test "returns [identifier | values] when all accesses are AccessLiteral" do
      accesses = [
        %Gas.AccessLiteral{loc: @loc, value: "a"},
        %Gas.AccessLiteral{loc: @loc, value: "b"}
      ]

      var = %Variable{loc: @loc, identifier: "x", accesses: accesses, original_name: "x.a.b"}
      assert Variable.static_keys(var) == ["x", "a", "b"]
    end

    test "preserves integer access values" do
      accesses = [%Gas.AccessLiteral{loc: @loc, value: 0}]
      var = %Variable{loc: @loc, identifier: "x", accesses: accesses, original_name: "x[0]"}
      assert Variable.static_keys(var) == ["x", 0]
    end

    test "returns nil when any access is AccessVariable" do
      access_var = %Variable{loc: @loc, identifier: "i", accesses: [], original_name: "i"}

      accesses = [
        %Gas.AccessLiteral{loc: @loc, value: "a"},
        %Gas.AccessVariable{loc: @loc, variable: access_var}
      ]

      var = %Variable{loc: @loc, identifier: "x", accesses: accesses, original_name: "x.a[i]"}
      assert Variable.static_keys(var) == nil
    end

    test "omits identifier when nil (bracket-only access like [foo])" do
      accesses = [%Gas.AccessLiteral{loc: @loc, value: "foo"}]
      var = %Variable{loc: @loc, identifier: nil, accesses: accesses, original_name: "[foo]"}
      assert Variable.static_keys(var) == ["foo"]
    end
  end

  describe "compile-time static_keys population" do
    test "Gas.Compiler.Interpolation.expand walks the parse_tree and sets static_keys" do
      {:ok, parsed} = Gas.parse("{{ x.a.b }}")
      expanded = Gas.Compiler.Interpolation.expand(parsed, [])

      [%Gas.Object{argument: %Variable{} = var}] = expanded.parsed_template
      assert var.static_keys == ["x", "a", "b"]
    end

    test "Compiler.Interpolation.expand leaves dynamic-access variables alone" do
      {:ok, parsed} = Gas.parse("{{ x[i] }}")
      expanded = Gas.Compiler.Interpolation.expand(parsed, [])

      [%Gas.Object{argument: %Variable{} = var}] = expanded.parsed_template
      assert var.static_keys == nil
    end
  end

  describe "parse/1" do
    test "variable" do
      template = "var123 rest"

      assert parse(template) == {
               :ok,
               %Variable{
                 loc: %Loc{column: 3, line: 1},
                 original_name: "var123",
                 accesses: [],
                 identifier: "var123"
               },
               [
                 {:identifier, %{column: 10, line: 1}, "rest"},
                 {:end, %{line: 1, column: 14}}
               ]
             }
    end

    test "bracket variable" do
      template = "['a var'].foo }}"

      assert {
               :ok,
               %Variable{
                 accesses: [
                   %Gas.AccessLiteral{value: "a var"},
                   %Gas.AccessLiteral{value: "foo"}
                 ],
                 identifier: nil,
                 original_name: "['a var'].foo"
               },
               [end: %{column: 17, line: 1}]
             } = parse(template)
    end

    test "variable with accesses" do
      template = ~s{var1.var2["string"][123][var3]}

      assert parse(template) == {
               :ok,
               %Gas.Variable{
                 original_name: "var1.var2[\"string\"][123][var3]",
                 accesses: [
                   %Gas.AccessLiteral{
                     loc: %Loc{column: 8, line: 1},
                     value: "var2"
                   },
                   %Gas.AccessLiteral{
                     loc: %Loc{column: 13, line: 1},
                     value: "string"
                   },
                   %Gas.AccessLiteral{
                     loc: %Loc{column: 23, line: 1},
                     value: 123
                   },
                   %Gas.AccessVariable{
                     loc: %Loc{column: 28, line: 1},
                     variable: %Gas.Variable{
                       loc: %Loc{column: 28, line: 1},
                       original_name: "var3",
                       identifier: "var3",
                       accesses: []
                     }
                   }
                 ],
                 identifier: "var1",
                 loc: %Loc{column: 3, line: 1}
               },
               [end: %{column: 33, line: 1}]
             }
    end

    test "variable with nested accesses" do
      template = "var1[var2.var3].var4"

      assert parse(template) == {
               :ok,
               %Gas.Variable{
                 original_name: "var1[var2.var3].var4",
                 accesses: [
                   %Gas.AccessVariable{
                     loc: %Loc{column: 8, line: 1},
                     variable: %Gas.Variable{
                       original_name: "var2.var3",
                       loc: %Loc{column: 8, line: 1},
                       identifier: "var2",
                       accesses: [
                         %Gas.AccessLiteral{loc: %Loc{column: 13, line: 1}, value: "var3"}
                       ]
                     }
                   },
                   %Gas.AccessLiteral{
                     loc: %Loc{column: 19, line: 1},
                     value: "var4"
                   }
                 ],
                 identifier: "var1",
                 loc: %Loc{column: 3, line: 1}
               },
               [end: %{column: 23, line: 1}]
             }
    end

    test "nil" do
      assert parse("nil") == {
               :ok,
               %Gas.Literal{loc: %Loc{line: 1, column: 3}, value: nil},
               [end: %{line: 1, column: 6}]
             }
    end

    test "empty" do
      assert parse("empty") == {
               :ok,
               %Gas.Literal{loc: %Loc{line: 1, column: 3}, value: %Gas.Literal.Empty{}},
               [end: %{line: 1, column: 8}]
             }
    end

    test "true" do
      assert parse("true") == {
               :ok,
               %Gas.Literal{loc: %Loc{line: 1, column: 3}, value: true},
               [end: %{line: 1, column: 7}]
             }
    end

    test "false" do
      assert parse("false") == {
               :ok,
               %Gas.Literal{loc: %Loc{line: 1, column: 3}, value: false},
               [end: %{line: 1, column: 8}]
             }
    end

    test "blank" do
      assert parse("blank") == {
               :ok,
               %Gas.Literal{loc: %Loc{line: 1, column: 3}, value: ""},
               [end: %{line: 1, column: 8}]
             }
    end

    test "empty tokens" do
      assert parse("") == {:error, "Variable expected", %{line: 1, column: 3}}
    end

    test "broken accesses" do
      template = "var1[var2"

      assert parse(template) == {:error, "Argument access mal terminated", %{column: 12, line: 1}}
    end

    test "broken nested accesses" do
      template = "var1[var2.var3.]"

      assert parse(template) == {:error, "Argument access mal terminated", %{column: 17, line: 1}}
    end
  end
end
