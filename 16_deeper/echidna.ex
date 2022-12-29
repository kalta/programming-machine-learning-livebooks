Mix.install(
  [
    {:exla, "~> 0.4"},
    {:nx, "~> 0.4"},
    # TODO: use next released version
    # {:axon, "~> 0.3.1"},
    {:axon, git: "https://github.com/elixir-nx/axon", branch: "main"},
    {:kino, "~> 0.8.0"},
    {:kino_vega_lite, "~> 0.1.7"},
    {:vega_lite, "~> 0.1.6"},
    {:table_rex, "~> 3.1.1"}
  ],
  config: [nx: [default_backend: EXLA.Backend]]
)

defmodule C16.EchidnaDataset do
  import Nx.Defn

  @filename Path.join(["data", "echidna.txt"])

  @doc """
  Loads the echidna dataset and returns the input `x` and label `y` tensors.

  - the dataset has been shuffled
  - the input tensor is already normalized
  """
  def load() do
    with {:ok, binary} <- read_file() do
      # seed the random algorithm
      :rand.seed(:exsss, {1, 2, 3})

      tensor =
        binary
        |> parse()
        |> Nx.tensor()
        |> Nx.shuffle(axis: 0)

      # all the rows, only first 2 columns
      x = tensor[[0..-1//1, 0..1//1]] |> normalize_inputs()

      # all the rows, only 3rd column
      y =
        tensor[[0..-1//1, 2]]
        |> Nx.reshape({:auto, 1})
        |> Nx.as_type(:u8)

      %{x: x, y: y}
    end
  end

  def parse(binary) do
    binary
    |> String.split("\n", trim: true)
    |> Enum.slice(1..-1)
    |> Enum.map(fn row ->
      row
      |> String.split(" ", trim: true)
      |> Enum.map(&parse_float/1)
    end)
  end

  # Normalization (Min-Max Scalar)
  #
  # In this approach, the data is scaled to a fixed range — usually 0 to 1.
  # In contrast to standardization, the cost of having this bounded range
  # is that we will end up with smaller standard deviations,
  # which can suppress the effect of outliers.
  # Thus MinMax Scalar is sensitive to outliers.
  defnp normalize_inputs(x_raw) do
    # Compute the min/max over the first axe
    min = Nx.reduce_min(x_raw, axes: [0])
    max = Nx.reduce_max(x_raw, axes: [0])

    # After MinMaxScaling, the distributions are not centered
    # at zero and the standard deviation is not 1.
    # Thefore, subtract 0.5 to rescale data between -0.5 and 0.5
    (x_raw - min) / (max - min) - 0.5
  end

  # to handle both integer and float numbers
  defp parse_float(stringified_float) do
    {float, ""} = Float.parse(stringified_float)
    float
  end

  def read_file() do
    if File.exists?(@filename) do
      File.read(@filename)
    else
      {:error, "The file #{@filename} is missing!"}
    end
  end
end


%{x: x_all, y: y_all} = C16.EchidnaDataset.load()

size = (elem(Nx.shape(x_all), 0) / 3) |> ceil()

[x_train, x_validation, x_test] = Nx.to_batched(x_all, size) |> Enum.to_list()
[y_train, y_validation, y_test] = Nx.to_batched(y_all, size) |> Enum.to_list()

data = %{
  x_train: x_train,
  x_validation: x_validation,
  x_test: x_test,
  y_train: y_train,
  y_validation: y_validation,
  y_test: y_test
}

x_train = data.x_train
x_validation = data.x_validation

# One-hot encode the labels
y_train = Nx.equal(data.y_train, Nx.tensor(Enum.to_list(0..1)))
y_validation = Nx.equal(data.y_validation, Nx.tensor(Enum.to_list(0..1)))

batch_size = 25

train_inputs = Nx.to_batched(x_train, batch_size)
train_labels = Nx.to_batched(y_train, batch_size)
train_batches = Stream.zip(train_inputs, train_labels)

validation_data = [{x_validation, y_validation}]

epochs = 30_000

################# MODEL 1
#
# model =
#   Axon.input("data", shape: Nx.shape(x_train))
#   |> Axon.dense(100, activation: :sigmoid)
#   |> Axon.dense(2, activation: :softmax)

# loop =
#   model
#   |> Axon.Loop.trainer(:categorical_cross_entropy, Axon.Optimizers.rmsprop(0.001))
#   |> Axon.Loop.metric(:accuracy)
#   |> Axon.Loop.validate(model, validation_data)

# {microsec, params} = :timer.tc(fn ->
#   Axon.Loop.run(loop, train_batches, %{}, epochs: epochs, compiler: EXLA)
# end)
#
# IO.inspect("TRAINING CONCLUDED IN #{ceil(microsec / (60 * 1_000_000))} minutes.")
#
# {:ok, file1} = File.open("./model1_params.term", [:write])
# Nx.serialize(params) |> then(& IO.binwrite(file1, &1))
# :ok = File.close(file1)
#
########################

################# MODEL 2
#
new_model =
  Axon.input("data", shape: Nx.shape(x_train))
  |> Axon.dense(100, activation: :sigmoid)
  |> Axon.dense(30, activation: :sigmoid)
  |> Axon.dense(2, activation: :softmax)

new_loop =
  new_model
  |> Axon.Loop.trainer(:categorical_cross_entropy, Axon.Optimizers.rmsprop(0.001))
  |> Axon.Loop.metric(:accuracy)
  |> Axon.Loop.validate(new_model, validation_data)

{microsec, new_params} = :timer.tc(fn ->
  Axon.Loop.run(new_loop, train_batches, %{}, epochs: epochs, compiler: EXLA)
end)

IO.inspect("TRAINING CONCLUDED IN #{ceil(microsec / (60 * 1_000_000))} minutes.")

{:ok, file2} = File.open("./model2_params.term", [:write])
Nx.serialize(new_params) |> then(& IO.binwrite(file2, &1))
:ok = File.close(file2)
#
########################