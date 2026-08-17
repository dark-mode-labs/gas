defmodule Gas.ContextTest do
  use ExUnit.Case, async: true
  alias Gas.{AccessLiteral, AccessVariable, Context, Literal, Variable}

  @loc %Gas.Parser.Loc{line: 1, column: 1}

  describe "get_in/3" do
    test "counter_vars scope only" do
      var = %Variable{original_name: "x", loc: @loc, identifier: "x", accesses: []}
      context = %Context{counter_vars: %{"x" => 1}}
      assert Context.get_in(context, var, [:counter_vars]) == {:ok, 1, context}
    end

    test "vars scope only" do
      var = %Variable{original_name: "x", loc: @loc, identifier: "x", accesses: []}
      context = %Context{vars: %{"x" => 1}}
      assert Context.get_in(context, var, [:vars]) == {:ok, 1, context}
    end

    test "var scope with false value" do
      var = %Variable{original_name: "x", loc: @loc, identifier: "x", accesses: []}
      context = %Context{vars: %{"x" => false}}
      assert Context.get_in(context, var, [:vars]) == {:ok, false, context}
    end

    test "var scope with nil value" do
      var = %Variable{original_name: "x", loc: @loc, identifier: "x", accesses: []}
      context = %Context{vars: %{"x" => nil}}
      assert Context.get_in(context, var, [:vars]) == {:ok, nil, context}
    end

    test "iteration_vars scope only" do
      var = %Variable{original_name: "x", loc: @loc, identifier: "x", accesses: []}
      context = %Context{iteration_vars: %{"x" => 1}}
      assert Context.get_in(context, var, [:iteration_vars]) == {:ok, 1, context}
    end

    test "nested access" do
      accesses = [%AccessLiteral{loc: @loc, value: "y"}]
      var = %Variable{original_name: "x.y", loc: @loc, identifier: "x", accesses: accesses}
      context = %Context{vars: %{"x" => %{"y" => 1}}}
      assert Context.get_in(context, var, [:vars]) == {:ok, 1, context}
    end

    test "nested access literal not found" do
      accesses = [%AccessLiteral{loc: @loc, value: "y"}]
      var = %Variable{original_name: "x.y", loc: @loc, identifier: "x", accesses: accesses}

      context = %Context{vars: %{"x" => "y"}}
      assert Context.get_in(context, var, [:vars]) == {:error, {:not_found, ["x", "y"]}, context}
    end

    test "nested access variable" do
      accesses = [
        %AccessVariable{
          loc: @loc,
          variable: %Variable{original_name: "y", identifier: "y", loc: @loc, accesses: []}
        }
      ]

      var = %Variable{original_name: "x[y]", loc: @loc, identifier: "x", accesses: accesses}

      context = %Context{vars: %{"y" => "v", "x" => %{"v" => "value"}}}
      assert Context.get_in(context, var, [:vars]) == {:ok, "value", context}
    end

    test "nested access nil" do
      accesses = [%AccessLiteral{loc: @loc, value: "y"}]
      var = %Variable{original_name: "x[\"y\"]", loc: @loc, identifier: "x", accesses: accesses}
      context = %Context{vars: %{"x" => 1}}
      assert Context.get_in(context, var, [:vars]) == {:error, {:not_found, ["x", "y"]}, context}
    end

    test "counter_vars & vars scopes with both keys existing" do
      var = %Variable{original_name: "x", loc: @loc, identifier: "x", accesses: []}
      context = %Context{vars: %{"x" => 1}, counter_vars: %{"x" => 2}}
      assert Context.get_in(context, var, [:vars, :counter_vars]) == {:ok, 1, context}
    end

    test "counter_vars & vars scopes with counter_vars key existing" do
      var = %Variable{original_name: "x", loc: @loc, identifier: "x", accesses: []}
      context = %Context{counter_vars: %{"x" => 2}}
      assert Context.get_in(context, var, [:vars, :counter_vars]) == {:ok, 2, context}
    end

    test "list access" do
      accesses = [%AccessLiteral{loc: @loc, value: 1}]
      var = %Variable{original_name: "x[1]", loc: @loc, identifier: "x", accesses: accesses}
      context = %Context{vars: %{"x" => ["a", "b", "c"]}}
      assert Context.get_in(context, var, [:vars]) == {:ok, "b", context}
    end

    test "list size" do
      accesses = [%AccessLiteral{loc: @loc, value: "size"}]
      var = %Variable{original_name: "x.size", loc: @loc, identifier: "x", accesses: accesses}
      context = %Context{vars: %{"x" => ["a", "b", "c"]}}
      assert Context.get_in(context, var, [:vars]) == {:ok, 3, context}
    end

    test "map size" do
      accesses = [%AccessLiteral{loc: @loc, value: "size"}]
      var = %Variable{original_name: "x.size", loc: @loc, identifier: "x", accesses: accesses}
      context = %Context{vars: %{"x" => %{"a" => 1, "b" => 2}}}
      assert Context.get_in(context, var, [:vars]) == {:ok, 2, context}
    end

    test "map size key" do
      accesses = [%AccessLiteral{loc: @loc, value: "size"}]
      var = %Variable{original_name: "x.size", loc: @loc, identifier: "x", accesses: accesses}
      context = %Context{vars: %{"x" => %{"a" => 1, "b" => 2, "size" => 42}}}
      assert Context.get_in(context, var, [:vars]) == {:ok, 42, context}
    end
  end

  describe "get_in/3 with pre-flattened static_keys" do
    test "fast path resolves a value through the static key list" do
      var = %Variable{
        original_name: "x.a.b",
        loc: @loc,
        identifier: "x",
        accesses: [
          %AccessLiteral{loc: @loc, value: "a"},
          %AccessLiteral{loc: @loc, value: "b"}
        ],
        static_keys: ["x", "a", "b"]
      }

      context = %Context{vars: %{"x" => %{"a" => %{"b" => "leaf"}}}}
      assert Context.get_in(context, var, [:vars]) == {:ok, "leaf", context}
    end

    test "fast path returns not_found when path is missing" do
      var = %Variable{
        original_name: "x.a.b",
        loc: @loc,
        identifier: "x",
        accesses: [
          %AccessLiteral{loc: @loc, value: "a"},
          %AccessLiteral{loc: @loc, value: "b"}
        ],
        static_keys: ["x", "a", "b"]
      }

      context = %Context{vars: %{"x" => %{"a" => %{}}}}

      assert Context.get_in(context, var, [:vars]) ==
               {:error, {:not_found, ["x", "a", "b"]}, context}
    end

    test "fast path uses scope precedence (iteration_vars > vars)" do
      var = %Variable{
        original_name: "x.a",
        loc: @loc,
        identifier: "x",
        accesses: [%AccessLiteral{loc: @loc, value: "a"}],
        static_keys: ["x", "a"]
      }

      context = %Context{
        iteration_vars: %{"x" => %{"a" => "iter"}},
        vars: %{"x" => %{"a" => "vars"}}
      }

      assert Context.get_in(context, var, [:iteration_vars, :vars]) == {:ok, "iter", context}
    end

    test "fast path falls back to vars when iteration_vars path doesn't resolve" do
      var = %Variable{
        original_name: "x.a",
        loc: @loc,
        identifier: "x",
        accesses: [%AccessLiteral{loc: @loc, value: "a"}],
        static_keys: ["x", "a"]
      }

      context = %Context{
        iteration_vars: %{"x" => %{}},
        vars: %{"x" => %{"a" => "vars"}}
      }

      assert Context.get_in(context, var, [:iteration_vars, :vars]) == {:ok, "vars", context}
    end
  end

  defmodule CustomMatcher do
    def match(_, _), do: {:ok, 42}
  end

  describe "get_in/3 with custom matcher module" do
    setup do
      context = %Context{matcher_module: CustomMatcher}
      {:ok, context: context}
    end

    test "counter_vars scope only", %{context: context} do
      var = %Variable{original_name: "x", loc: @loc, identifier: "x", accesses: []}
      context = %{context | counter_vars: %{"x" => 1}}
      assert Context.get_in(context, var, [:counter_vars]) == {:ok, 42, context}
    end

    test "vars scope only", %{context: context} do
      var = %Variable{original_name: "x", loc: @loc, identifier: "x", accesses: []}
      context = %{context | vars: %{"x" => 1}}
      assert Context.get_in(context, var, [:vars]) == {:ok, 42, context}
    end

    test "var scope with false value", %{context: context} do
      var = %Variable{original_name: "x", loc: @loc, identifier: "x", accesses: []}
      context = %{context | vars: %{"x" => false}}
      assert Context.get_in(context, var, [:vars]) == {:ok, 42, context}
    end

    test "var scope with nil value", %{context: context} do
      var = %Variable{original_name: "x", loc: @loc, identifier: "x", accesses: []}
      context = %{context | vars: %{"x" => nil}}
      assert Context.get_in(context, var, [:vars]) == {:ok, 42, context}
    end

    test "iteration_vars scope only", %{context: context} do
      var = %Variable{original_name: "x", loc: @loc, identifier: "x", accesses: []}
      context = %{context | iteration_vars: %{"x" => 1}}
      assert Context.get_in(context, var, [:iteration_vars]) == {:ok, 42, context}
    end
  end

  describe "run_cycle/2" do
    @one %Literal{loc: @loc, value: "one"}
    @two %Literal{loc: @loc, value: "two"}
    @three %Literal{loc: @loc, value: "three"}

    test "first run" do
      values = [@one, @two, @three]

      context = %Context{cycle_state: %{}}

      new_context = %Context{
        cycle_state: %{
          "l:one,l:two,l:three" => {0, %{0 => @one, 1 => @two, 2 => @three}}
        }
      }

      assert Context.run_cycle(context, nil, values) == {new_context, @one}
    end

    test "second run" do
      values = [@one, @two, @three]

      context = %Context{
        cycle_state: %{
          "l:one,l:two,l:three" => {0, %{0 => @one, 1 => @two, 2 => @three}}
        }
      }

      new_context = %Context{
        cycle_state: %{
          "l:one,l:two,l:three" => {1, %{0 => @one, 1 => @two, 2 => @three}}
        }
      }

      assert Context.run_cycle(context, nil, values) == {new_context, @two}
    end

    test "third run" do
      values = [@one, @two, @three]

      context = %Context{
        cycle_state: %{
          "l:one,l:two,l:three" => {1, %{0 => @one, 1 => @two, 2 => @three}}
        }
      }

      new_context = %Context{
        cycle_state: %{
          "l:one,l:two,l:three" => {2, %{0 => @one, 1 => @two, 2 => @three}}
        }
      }

      assert Context.run_cycle(context, nil, values) == {new_context, @three}
    end

    test "fourth run - loops back" do
      values = [@one, @two, @three]

      context = %Context{
        cycle_state: %{
          "l:one,l:two,l:three" => {2, %{0 => @one, 1 => @two, 2 => @three}}
        }
      }

      new_context = %Context{
        cycle_state: %{
          "l:one,l:two,l:three" => {0, %{0 => @one, 1 => @two, 2 => @three}}
        }
      }

      assert Context.run_cycle(context, nil, values) == {new_context, @one}
    end

    test "named first run" do
      name = @one
      values = [@one, @two, @three]

      context = %Context{cycle_state: %{}}

      new_context = %Context{
        cycle_state: %{
          "one" => {0, %{0 => @one, 1 => @two, 2 => @three}}
        }
      }

      assert Context.run_cycle(context, name, values) == {new_context, @one}
    end

    test "named second run" do
      name = @one
      values = [@one, @two, @three]

      context = %Context{
        cycle_state: %{
          "one" => {0, %{0 => @one, 1 => @two, 2 => @three}}
        }
      }

      new_context = %Context{
        cycle_state: %{
          "one" => {1, %{0 => @one, 1 => @two, 2 => @three}}
        }
      }

      assert Context.run_cycle(context, name, values) == {new_context, @two}
    end

    test "named third run" do
      name = @one
      values = [@one, @two, @three]

      context = %Context{
        cycle_state: %{
          "one" => {1, %{0 => @one, 1 => @two, 2 => @three}}
        }
      }

      new_context = %Context{
        cycle_state: %{
          "one" => {2, %{0 => @one, 1 => @two, 2 => @three}}
        }
      }

      assert Context.run_cycle(context, name, values) == {new_context, @three}
    end

    test "named fourth run - loops back" do
      name = @one
      values = [@one, @two, @three]

      context = %Context{
        cycle_state: %{
          "one" => {2, %{0 => @one, 1 => @two, 2 => @three}}
        }
      }

      new_context = %Context{
        cycle_state: %{
          "one" => {0, %{0 => @one, 1 => @two, 2 => @three}}
        }
      }

      assert Context.run_cycle(context, name, values) == {new_context, @one}
    end
  end

  describe "scope resolution agrees with the original reduce" do
    # Checked against the algorithm it replaced, for every combination of outcomes.
    @shapes [:absent, :nil_value, :value]

    defp scope_map(:absent), do: %{}
    defp scope_map(:nil_value), do: %{"x" => nil}
    defp scope_map(:value), do: %{"x" => :found}

    defp scope_result(:absent), do: {:error, :not_found}
    defp scope_result(:nil_value), do: {:ok, nil}
    defp scope_result(:value), do: {:ok, :found}

    # Verbatim the reduce that get_from_scope/3 used before scan_scopes/4.
    defp reference(results, keys) do
      results
      |> Enum.reverse()
      |> Enum.reduce({:error, {:not_found, keys}}, fn
        {:ok, nil}, acc = {:ok, _} -> acc
        value = {:ok, _}, _acc -> value
        _value, acc -> acc
      end)
    end

    test "every combination of scope outcomes resolves identically" do
      variable = %Gas.Variable{
        loc: %Gas.Parser.Loc{line: 1, column: 1},
        identifier: "x",
        accesses: [],
        original_name: "x",
        static_keys: ["x"]
      }

      scopes = Gas.Context.default_scopes()

      for iteration <- @shapes, vars <- @shapes, counters <- @shapes do
        shapes = %{iteration_vars: iteration, vars: vars, counter_vars: counters}

        context = %Gas.Context{
          iteration_vars: scope_map(iteration),
          vars: scope_map(vars),
          counter_vars: scope_map(counters)
        }

        expected = reference(Enum.map(scopes, &scope_result(shapes[&1])), ["x"])
        actual = Gas.Context.get_in(context, variable, scopes, [])

        assert {elem(actual, 0), elem(actual, 1)} == {elem(expected, 0), elem(expected, 1)},
               "disagreed for #{inspect(shapes)}: got #{inspect(actual)}, want #{inspect(expected)}"
      end
    end
  end
end
