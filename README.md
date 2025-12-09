# Gas

Gas is a fork of [Solid](https://github.com/edgurgel/solid), an implementation in Elixir of the [Liquid](https://shopify.github.io/liquid/) template language with strict parsing. Gas expands on the Solid foundation and focuses primarily on having full parity with the Liquid convention and specification.

## Basic Usage

```elixir
iex> template = "My name is {{ user.name }}"
iex> {:ok, template} = Gas.parse(template)
iex> Gas.render!(template, %{ "user" => %{ "name" => "José" } }) |> to_string
"My name is José"
```

## Installation

The package can be installed with:

```elixir
def deps do
  [{:gas, "~> 1.0"}]
end
```

## Custom tags

To implement a new tag you need to create a new module that implements the `Tag` behaviour. It must implement a `parse/3` function that returns a struct that implements `Gas.Renderable`. Here is a simple example:

```elixir
defmodule CurrentYear do
  @enforce_keys [:loc]
  defstruct [:loc]

  @behaviour Gas.Tag

  @impl true
  def parse("get_current_year", loc, context) do
    with {:ok, [{:end, _}], context} <- Gas.Lexer.tokenize_tag_end(context) do
      {:ok, %__MODULE__{loc: loc}, context}
    end
  end

  defimpl Gas.Renderable do
    def render(_tag, context, _options) do
      {[to_string(Date.utc_today().year)], context}
    end
  end
end
```

Now to use it simply pass a `:tags` option to `Gas.parse/2` including your custom tag:

```elixir
tags = Map.put(Gas.Tag.default_tags(), "get_current_year", CurrentYear)
Gas.parse!("{{ get_current_year }}", tags: tags)
```

## Strict rendering

By default Gas will treat any missing filters as a violation and report it as such. `Gas.render!/3` raises if `strict_variables: true` is passed and there are missing variables.

## Preprocessing

## Standard Filters

## Translation

## Using structs in context

In order to pass structs to context you need to implement protocol `Gas.Matcher` for that. That protocol consist of one function `def match(data, keys)`. First argument is struct being provided and second is list of string, which are keys passed after `.` to the struct.

For example:

```elixir
defmodule UserProfile do
  defstruct [:full_name]

  defimpl Gas.Matcher do
    def match(user_profile, ["full_name"]), do: {:ok, user_profile.full_name}
  end
end

defmodule User do
  defstruct [:email]

  def load_profile(%User{} = _user) do
    # implementation omitted
    %UserProfile{full_name: "John Doe"}
  end

  defimpl Gas.Matcher do
    def match(user, ["email"]), do: {:ok, user.email}
    def match(user, ["profile" | keys]), do: user |> User.load_profile() |> @protocol.match(keys)
  end
end

template = ~s({{ user.email}}: {{ user.profile.full_name }})
context = %{
  "user" => %User{email: "test@example.com"}
}

template |> Gas.parse!() |> Gas.render!(context) |> to_string()
# => test@example.com: John Doe
```

If the `Gas.Matcher` protocol is not enough one can provide a module like this:

```elixir
defmodule MyMatcher do
  def match(_data, _keys), do: {:ok, 42}
end

# ...
Gas.render!(template, %{"number" => 4}, matcher_module: MyMatcher)
```

## Contributing

When adding new functionality or fixing bugs consider adding a new test case here inside `test/gas/integration/scenarios`. These scenarios are tested against the Ruby gem so we can try to stay as close as possible to the original implementation.

## Copyright and License

Copyright (c) 2016-2025 Praveen Rangarajan

This work is free. You can redistribute it and/or modify it under the
terms of the MIT License. See the [LICENSE.md](./LICENSE.md) file for more details.
