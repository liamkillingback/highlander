defmodule Highlander do
  @external_resource "README.md"
  @moduledoc @external_resource
             |> File.read!()
             |> String.split("<!-- MDOC !-->")
             |> Enum.fetch!(1)

  use GenServer
  require Logger

  def child_spec(child_child_spec) do
    child_child_spec = Supervisor.child_spec(child_child_spec, [])

    Logger.debug("Starting Highlander with #{inspect(child_child_spec.id)} as uniqueness key")

    %{
      id: child_child_spec.id,
      start: {GenServer, :start_link, [__MODULE__, child_child_spec, []]}
    }
  end

  @impl true
  def init(child_spec) do
    Process.flag(:trap_exit, true)
    {:ok, register(%{child_spec: child_spec})}
  end

  @impl true
  def handle_info({:DOWN, ref, :process, _, _}, %{ref: ref} = state) do
    {:noreply, register(state)}
  end

  def handle_info({:EXIT, _pid, :name_conflict}, %{pid: pid} = state) do
    :ok = Supervisor.stop(pid, :shutdown)
    {:stop, {:shutdown, :name_conflict}, Map.delete(state, :pid)}
  end

  def handle_info({:EXIT, _pid, :shutdown}, state) do
    {:stop, {:shutdown, :name_conflict}, Map.delete(state, :pid)}
  end

  def handle_info({_, _} = msg, state) do
    case Map.get(state, :child_pid) do
      nil ->
        # We're not the leader, forward to the global registered leader
        pid = :global.whereis_name(name(state))
        send(pid, msg)

      child_pid ->
        # We're the leader, forward to our child
        send(child_pid, msg)
    end

    {:noreply, state}
  end

  @impl true
  def handle_call(msg, _from, state) do
    {:reply, GenServer.call(state.child_pid, msg), state}
  end

  @impl true
  def handle_cast(msg, state) do
    GenServer.cast(state.child_pid, msg)

    {:noreply, state}
  end

  @impl true
  def terminate(reason, %{pid: pid}) do
    :ok = Supervisor.stop(pid, reason)
  end

  def terminate(_, _), do: nil

  defp name(%{child_spec: %{id: global_name}}) do
    {__MODULE__, global_name}
  end

  defp handle_conflict(_name, pid1, pid2) do
    Process.exit(pid2, :name_conflict)
    pid1
  end

  defp register(state) do
    case :global.register_name(name(state), self(), &handle_conflict/3) do
      :yes -> start(state)
      :no -> monitor(state)
    end
  end

  defp start(state) do
    {:ok, supervisor_pid} = Supervisor.start_link([state.child_spec], strategy: :one_for_one)
    child_pid = get_child_pid(supervisor_pid)
    Map.merge(state, %{pid: supervisor_pid, child_pid: child_pid})
  end

  defp get_child_pid(supervisor_pid) do
    case Supervisor.which_children(supervisor_pid) do
      [{_id, child_pid, _type, _modules}] when is_pid(child_pid) -> child_pid
      _ -> nil
    end
  end

  defp monitor(state) do
    case :global.whereis_name(name(state)) do
      :undefined ->
        register(state)

      pid ->
        ref = Process.monitor(pid)
        %{child_spec: state.child_spec, ref: ref, pid: pid}
    end
  end
end
