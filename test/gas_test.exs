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
               # FIXME this should somehow point out which file?
               # Check how liquid does this
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
end
