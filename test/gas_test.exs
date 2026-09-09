defmodule GasTest do
  use ExUnit.Case, async: true

  defmodule TestFileSystem do
    @behaviour Gas.FileSystem

    @impl true
    def read_template_file("error", _opts), do: {:ok, "{% error %}"}
    def read_template_file("missing_var", _opts), do: {:ok, "{{ var3 }}"}
  end

  describe "parser/2" do
    test "basic" do
      template = "{{ form.title }}"

      assert Gas.parse(template) ==
               {:ok,
                %Gas.Template{
                  parsed_template: [
                    %Gas.Object{
                      loc: %Gas.Parser.Loc{column: 4, line: 1},
                      argument: %Gas.Variable{
                        original_name: "form.title",
                        loc: %Gas.Parser.Loc{column: 4, line: 1},
                        identifier: "form",
                        accesses: [
                          %Gas.AccessLiteral{
                            loc: %Gas.Parser.Loc{column: 9, line: 1},
                            value: "title"
                          }
                        ]
                      },
                      filters: []
                    }
                  ]
                }}
    end

    test "single error" do
      template = "{{ form.title"

      assert Gas.parse(template) == {
               :error,
               %Gas.TemplateError{
                 errors: [
                   %Gas.ParserError{
                     meta: %{line: 1, column: 1},
                     reason: "Tag or Object not properly terminated",
                     text: "{{ form.title"
                   }
                 ]
               }
             }
    end

    test "multiple errors" do
      template = """
      {{ - }}

      {% unknown %}

      {% if true %}
      {% endunless % }
      {% echo 'yo' %}
      """

      assert Gas.parse(template) == {
               :error,
               %Gas.TemplateError{
                 errors: [
                   %Gas.ParserError{
                     meta: %{column: 4, line: 1},
                     reason: "Unexpected character '-'",
                     text: "{{ - }}"
                   },
                   %Gas.ParserError{
                     meta: %{column: 1, line: 3},
                     reason: "Unexpected tag 'unknown'",
                     text: "{% unknown %}"
                   },
                   %Gas.ParserError{
                     meta: %{column: 1, line: 6},
                     reason:
                       "Expected one of 'elsif', 'else', 'endif' tags. Got: Unexpected tag 'endunless'",
                     text: "{% endunless % }"
                   },
                   %Gas.ParserError{
                     meta: %{column: 1, line: 6},
                     reason: "Unexpected tag 'endunless'",
                     text: "{% endunless % }"
                   }
                 ]
               }
             }
    end

    test "errors inside render tag" do
      template = """
      begin
      {% render 'error' %}
      end
      """

      template = Gas.parse!(template)

      assert Gas.render(template, %{}, file_system: {TestFileSystem, nil}) ==
               {
                 :error,
                 [
                   %Gas.TemplateError{
                     __exception__: true,
                     errors: [
                       %Gas.ParserError{
                         reason: "Unexpected tag 'error'",
                         meta: %{line: 1, column: 1},
                         text: "{% error %}"
                       }
                     ]
                   }
                 ],
                 ["begin\n", [], "\nend\n"]
               }
    end
  end

  describe "render!/3" do
    test "text rendering" do
      template = "simple text"

      assert template
             |> Gas.parse!()
             |> Gas.render!(%{})
             |> IO.iodata_to_binary() == "simple text"
    end

    test "object rendering" do
      template = "{{ var1 | upcase }}"

      assert template
             |> Gas.parse!()
             |> Gas.render!(%{"var1" => "yo"})
             |> IO.iodata_to_binary() == "YO"
    end

    test "empty object rendering" do
      template = "{{}}"

      assert template
             |> Gas.parse!()
             |> Gas.render!(%{})
             |> IO.iodata_to_binary() == ""
    end

    test "echo tag rendering" do
      template = "{% echo 'yo' %}"

      assert template
             |> Gas.parse!()
             |> Gas.render!(%{})
             |> IO.iodata_to_binary() == "yo"
    end

    test "assign tag rendering" do
      template = "{%- assign var1 = 'yo' -%} {{- var1 -}}"

      assert template
             |> Gas.parse!()
             |> Gas.render!(%{})
             |> IO.iodata_to_binary() == "yo"
    end

    test "custom tag get_current_year rendering" do
      template = "{% get_current_year %}"

      tags =
        Gas.Tag.default_tags()
        |> Map.put("get_current_year", CustomTags.CurrentYear)

      assert template
             |> Gas.parse!(tags: tags)
             |> Gas.render!(%{})
             |> IO.iodata_to_binary() == to_string(Date.utc_today().year)
    end

    test "custom tag myblock rendering" do
      template = """
      {%- myblock -%}
        {%- echo 'yo' -%}
        {%- assign var1 = "foo" -%}
        {{- var1 -}}
      {%- endmyblock -%}
      """

      tags =
        Gas.Tag.default_tags()
        |> Map.put("myblock", CustomTags.CustomBrackedWrappedTag)

      assert template
             |> Gas.parse!(tags: tags)
             |> Gas.render!(%{})
             |> IO.iodata_to_binary() == "yofoo"
    end
  end

  describe "render/3 options to context" do
    test "scopes from opts narrows variable resolution" do
      template = Gas.parse!("{{ x }}")

      context = %Gas.Context{
        vars: %{"x" => "from_vars"},
        counter_vars: %{"x" => "from_counter"}
      }

      {:ok, vars_result, _} = Gas.render(template, context, scopes: [:vars])
      assert IO.iodata_to_binary(vars_result) == "from_vars"

      {:ok, counter_result, _} = Gas.render(template, context, scopes: [:counter_vars])
      assert IO.iodata_to_binary(counter_result) == "from_counter"
    end

    test "scopes set on the Context are honored when opts omits scopes" do
      template = Gas.parse!("{{ x }}")

      context = %Gas.Context{
        vars: %{"x" => "from_vars"},
        counter_vars: %{"x" => "from_counter"},
        scopes: [:counter_vars]
      }

      {:ok, result, _} = Gas.render(template, context, [])
      assert IO.iodata_to_binary(result) == "from_counter"
    end

    test "strict_variables on the Context fires UndefinedVariableError" do
      template = Gas.parse!("{{ missing }}")

      context = %Gas.Context{vars: %{}, strict_variables: true}

      {:error, errors, _partial} = Gas.render(template, context, [])

      assert [%Gas.UndefinedVariableError{variable: ["missing"]}] = errors
    end
  end

  describe "break/continue propagation through nested render() calls" do
    test "continue inside for-loop body does not duplicate accumulated output" do
      template =
        Gas.parse!("""
        {% for i in (1..5) %}
          {% if i == 4 %}x{% continue %}{% else %}{{ i }}{% endif %}
        {% endfor %}
        after
        """)

      {:ok, result, _errors} = Gas.render(template, %{})
      output = IO.iodata_to_binary(result)

      # Each digit appears exactly once
      assert String.split(output, "1", trim: false) |> length() == 2
      assert String.split(output, "2", trim: false) |> length() == 2
      assert String.split(output, "5", trim: false) |> length() == 2
      assert String.contains?(output, "after")
    end

    test "continue outside any for-loop terminates render with accumulated output" do
      template =
        Gas.parse!("""
        before
        {% continue %}
        after
        """)

      {:ok, result, _errors} = Gas.render(template, %{})
      output = IO.iodata_to_binary(result)

      assert String.contains?(output, "before")
      refute String.contains?(output, "after")
    end

    test "for-loop completes fully, then continue after endfor terminates render" do
      template =
        Gas.parse!("""
        {% for i in (1..3) %}{{ i }} {% endfor %}
        keep
        {% continue %}
        drop
        """)

      {:ok, result, _errors} = Gas.render(template, %{})
      output = IO.iodata_to_binary(result)

      assert String.contains?(output, "1 2 3")
      # Loop output appears exactly once
      assert length(String.split(output, "1 2 3", trim: false)) == 2
      assert String.contains?(output, "keep")
      refute String.contains?(output, "drop")
    end
  end

  describe "do_render AssignTag inline" do
    test "assigns the resolved value to vars and returns empty iolist" do
      template = Gas.parse!("{% assign x = 1 %}{{ x }}")

      assert {:ok, result, _errors} = Gas.render(template, %{})
      assert IO.iodata_to_binary(result) == "1"
    end

    test "assign with filter on the right-hand side" do
      template = Gas.parse!("{% assign x = name | upcase %}{{ x }}")

      assert {:ok, result, _errors} = Gas.render(template, %{"name" => "bob"})
      assert IO.iodata_to_binary(result) == "BOB"
    end

    test "assign overrides prior value" do
      template = Gas.parse!("{% assign x = 1 %}{% assign x = 2 %}{{ x }}")

      assert {:ok, result, _errors} = Gas.render(template, %{})
      assert IO.iodata_to_binary(result) == "2"
    end
  end

  describe "Argument.get fast paths" do
    @loc %Gas.Parser.Loc{line: 1, column: 1}

    test "literal with no filters returns value without dispatching do_get/4" do
      arg = %Gas.Literal{loc: @loc, value: "hello"}
      context = %Gas.Context{}
      assert Gas.Argument.get(arg, context, []) == {:ok, "hello", context}
    end

    test "literal with filters still resolves through apply_filters" do
      arg = %Gas.Literal{loc: @loc, value: nil}

      filters = [
        %Gas.Filter{
          loc: @loc,
          function: "default",
          positional_arguments: [%Gas.Literal{loc: @loc, value: "fallback"}],
          named_arguments: %{}
        }
      ]

      {:ok, value, _ctx} = Gas.Argument.get(arg, %Gas.Context{}, filters)
      assert value == "fallback"
    end
  end

  describe "strict_variables" do
    test "object rendering" do
      template = "a{{ var1 }} {{ var2 }}b"

      {:error, error, partial_result} =
        template
        |> Gas.parse!()
        |> Gas.render(%{}, strict_variables: true)

      assert IO.iodata_to_binary(partial_result) == "a b"

      assert error == [
               %Gas.UndefinedVariableError{
                 variable: ["var1"],
                 original_name: "var1",
                 loc: %Gas.Parser.Loc{line: 1, column: 5}
               },
               %Gas.UndefinedVariableError{
                 variable: ["var2"],
                 original_name: "var2",
                 loc: %Gas.Parser.Loc{line: 1, column: 16}
               }
             ]
    end

    test "render tag no file system" do
      template = "a{{ var1 }} {{ var2 }}b {% render 'filesystem not configured' %}c"

      {:error, errors, partial_result} =
        template
        |> Gas.parse!()
        |> Gas.render(%{})

      assert IO.iodata_to_binary(partial_result) ==
               "a b c"

      assert errors == [
               %Gas.FileSystem.Error{
                 loc: %Gas.Parser.Loc{line: 1, column: 25},
                 reason: "This Gas context does not allow includes filesystem not configured."
               }
             ]
    end

    test "inner rendering" do
      template = "a{{ var1 }} {{ var2 }}b {% render 'missing_var' %}c"

      {:error, error, partial_result} =
        template
        |> Gas.parse!()
        |> Gas.render(%{}, strict_variables: true, file_system: {TestFileSystem, nil})

      assert IO.iodata_to_binary(partial_result) == "a b c"

      assert error == [
               %Gas.UndefinedVariableError{
                 variable: ["var1"],
                 original_name: "var1",
                 loc: %Gas.Parser.Loc{line: 1, column: 5}
               },
               %Gas.UndefinedVariableError{
                 variable: ["var2"],
                 original_name: "var2",
                 loc: %Gas.Parser.Loc{line: 1, column: 16}
               },
               %Gas.UndefinedVariableError{
                 variable: ["var3"],
                 original_name: "var3",
                 loc: %Gas.Parser.Loc{line: 1, column: 4}
               }
             ]
    end

    test "return errors when both strict_variables are on" do
      template = "a{{ var1 | non_existing_filter }} {{ var2 | capitalize }}b"

      {:error, error, _partial_result} =
        template
        |> Gas.parse!()
        |> Gas.render(%{})

      assert error == [
               %Gas.UndefinedFilterError{
                 loc: %Gas.Parser.Loc{column: 12, line: 1},
                 filter: "non_existing_filter"
               }
             ]

      {:error, error, _partial_result} =
        template
        |> Gas.parse!()
        |> Gas.render(%{}, strict_variables: true)

      assert error == [
               %Gas.UndefinedVariableError{
                 variable: ["var1"],
                 original_name: "var1",
                 loc: %Gas.Parser.Loc{line: 1, column: 5}
               },
               %Gas.UndefinedFilterError{
                 loc: %Gas.Parser.Loc{column: 12, line: 1},
                 filter: "non_existing_filter"
               },
               %Gas.UndefinedVariableError{
                 variable: ["var2"],
                 original_name: "var2",
                 loc: %Gas.Parser.Loc{line: 1, column: 38}
               }
             ]
    end

    test "undefined variable error message with multiple variables" do
      template =
        "{{ var1 }}\n{{ event.name }}\n{{ user.properties['name'] }}\n"

      {:error, [first_error, second_error, third_error], _partial_result} =
        template
        |> Gas.parse!()
        |> Gas.render(%{}, strict_variables: true, file_system: {TestFileSystem, nil})

      assert String.contains?(Gas.UndefinedVariableError.message(first_error), "var1")

      assert String.contains?(
               Gas.UndefinedVariableError.message(second_error),
               "event.name"
             )

      assert String.contains?(
               Gas.UndefinedVariableError.message(third_error),
               "user.properties['name']"
             )
    end

    test "undefined filter error message with line number" do
      template = "{{ var1 | not_a_filter }}"

      assert_raise Gas.RenderError,
                   "1 error(s) found while rendering\n1: Undefined filter not_a_filter",
                   fn ->
                     template
                     |> Gas.parse!()
                     |> Gas.render!(%{"var1" => "value"},
                       file_system: {TestFileSystem, nil}
                     )
                   end
    end
  end

  describe "precompile/2 with :on_codegen_miss" do
    defmodule EchoFileSystem do
      @behaviour Gas.FileSystem

      @impl true
      def read_template_file(name, _opts), do: {:ok, "<#{name}>{{ who }}"}
    end

    defp cached_opts(extra) do
      Keyword.merge(
        [file_system: {EchoFileSystem, nil}, cache_module: Gas.Caching.EtsCache, codegen: true],
        extra
      )
    end

    defp render_to_binary(template, vars, opts) do
      {:ok, out, _errors} = Gas.render(template, %Gas.Context{vars: vars}, opts)
      IO.iodata_to_binary(out)
    end

    test "a first precompile interprets, and the module lands on a later one" do
      test = self()
      name = "deferred-#{System.unique_integer([:positive])}"
      opts = cached_opts(on_codegen_miss: fn tree -> send(test, {:enqueued, tree}) end)

      assert {:ok, %Gas.Template{module: nil}} = Gas.precompile(name, opts)
      assert_received {:enqueued, tree}

      # What the host's own process does with the tree it was handed.
      assert {:ok, _module} = Gas.Compiler.Codegen.compile_cached(tree, %{}, opts)

      assert {:ok, %Gas.Template{module: module}} = Gas.precompile(name, opts)
      assert module, "the host compiled it, but the template cache never picked the module up"
    end

    test "the deferred render produces exactly what the compiled one does" do
      name = "parity-#{System.unique_integer([:positive])}"
      vars = %{"who" => "Ada"}

      deferred = cached_opts(on_codegen_miss: fn _tree -> :ok end)
      compiled = cached_opts(cache_module: Gas.Caching.NoCache)

      assert {:ok, %Gas.Template{module: nil} = d} = Gas.precompile(name, deferred)
      assert {:ok, %Gas.Template{module: m} = c} = Gas.precompile(name, compiled)
      assert m, "the comparison side did not compile, so this proves nothing"

      assert render_to_binary(d, vars, deferred) == render_to_binary(c, vars, compiled)
    end

    test "compiles inline when the host offers no callback" do
      name = "inline-#{System.unique_integer([:positive])}"

      assert {:ok, %Gas.Template{module: module}} = Gas.precompile(name, cached_opts([]))
      assert module
    end
  end
end
