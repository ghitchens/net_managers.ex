# Copyright 2014 LKC Technologies, Inc.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
# http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

defmodule Udhcpc do
  use GenServer

  defstruct ifname: nil,
            manager: nil,
            port: nil

  @doc """
  Start and link a Udhcpc process for the specified interface (i.e., eth0,
  wlan0). This function spawns a GenEvent for getting responses and
  notifications from the DHCP server. Call event_manager/1 to get the
  GenEvent pid.
  """
  def start_link(ifname) do
    { :ok, manager } = GenEvent.start_link
    start_link(ifname, manager)
  end

  @doc """
  Start and link a Udhcpc process for the specified interface (i.e., eth0,
  wlan0). Pass a GenEvent in to receive messages back from the DHCP server.
  """
  def start_link(ifname, event_manager) do
    GenServer.start_link(__MODULE__, {ifname, event_manager})
  end

  @doc """
  Get a reference to the GenEvent event manager in use by this Udhcpc
  """
  def event_manager(pid) do
    GenServer.call(pid, :event_manager)
  end

  @doc """
  Notify the DHCP server to release the IP address currently assigned to
  this interface. After calling this, be sure to disassociate the IP address
  from the interface so that packets don't accidentally get sent or processed.
  """
  def release(pid) do
    GenServer.call(pid, :release)
  end

  @doc """
  Renew the lease on the IP address with the DHCP server.
  """
  def renew(pid) do
    GenServer.call(pid, :renew)
  end


  def init({ifname, event_manager}) do
    path = System.find_executable("udhcpc") || raise "udhcpc not found"
    script = :code.priv_dir(:prototest) ++ '/udhcpc.sh'
    args = ['--interface', String.to_char_list(ifname), '--script', script, '--foreground']
      sudo_path = System.find_executable("sudo")
      args = [path] ++ args
      path = sudo_path
    IO.inspect path
    IO.inspect args
    port = Port.open({:spawn_executable, path},
                     [{:args, args}, :exit_status, :stderr_to_stdout, {:line, 256}])
    { :ok, %Udhcpc{ifname: ifname, manager: event_manager, port: port} }
  end

  def handle_call(:event_manager, _from, state) do
    {:reply, state.manager, state}
  end

  def handle_call(:renew, _from, state) do
    signal_udhcpc(state.port, "USR1")
    {:reply, :ok, state}
  end

  def handle_call(:release, _from, state) do
    signal_udhcpc(state.port, "USR2")
    {:reply, :ok, state}
  end

  def handle_info({_, {:data, {:eol, message}}}, state) do
    message
      |> List.to_string
      |> String.split(",")
      |> handle_udhcpc(state)
  end

  defp handle_udhcpc(["deconfig", interface | _rest], state) do
    IO.puts "Deconfigure #{interface}"
    GenEvent.notify(state.manager, {:udhcpc, self, {:deconfig, interface}})
    {:noreply, state}
  end
  defp handle_udhcpc(["bound", interface, ip, broadcast, subnet, router, domain, dns, _message], state) do
    IO.puts "Bound #{interface}: IP=#{ip}, dns=#{inspect dns}"
    GenEvent.notify(state.manager, {:udhcpc, self, {:bound, interface, ip, broadcast, subnet, router, domain, dns}})
    {:noreply, state}
  end
  defp handle_udhcpc(["renew", interface, ip, broadcast, subnet, router, domain, dns, _message], state) do
    IO.puts "Renew #{interface}"
    GenEvent.notify(state.manager, {:udhcpc, self, {:renew, interface, ip, broadcast, subnet, router, domain, dns}})
    {:noreply, state}
  end
  defp handle_udhcpc(["leasefail", interface, _ip, _broadcast, _subnet, _router, _domain, _dns, message], state) do
    IO.puts "#{interface}: leasefail #{message}"
    GenEvent.notify(state.manager, {:udhcpc, self, {:leasefail, interface}})
    {:noreply, state}
  end
  defp handle_udhcpc(["nak", interface, _ip, _broadcast, _subnet, _router, _domain, _dns, message], state) do
    IO.puts "#{interface}: NAK #{message}"
    GenEvent.notify(state.manager, {:udhcpc, self, {:nak, interface}})
    {:noreply, state}
  end
  defp handle_udhcpc(something_else, state) do
    msg = List.foldl(something_else, "", &<>/2)
    IO.puts "Got info message: #{msg}"
    {:noreply, state}
  end

  defp signal_udhcpc(port, signal) do
    {:os_pid, os_pid} = Port.info(port, :os_pid)
    System.cmd("sudo kill -#{signal} #{os_pid}")
  end
end

