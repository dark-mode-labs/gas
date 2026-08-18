ExUnit.start()
ExUnit.configure(exclude: :skip, exclude: :integration)
Application.put_env(:gas, :max_compiled_modules, 1_000_000)
