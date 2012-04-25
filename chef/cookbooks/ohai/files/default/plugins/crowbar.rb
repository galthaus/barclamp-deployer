# Copyright 2011, Dell
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#  http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#

require 'rubygems'
require 'socket'
require 'cstruct'
require 'timeout'

provides "crowbar_ohai"

class System
  def self.background_time_command(timeout, background, name, command)
    File.open("/tmp/tcpdump-#{name}.sh", "w+") { |fd|
      fd.puts("#!/bin/bash")
      fd.puts("#{command} &")
      fd.puts("sleep #{timeout}")
      fd.puts("kill %1")
    }

    system("chmod +x /tmp/tcpdump-#{name}.sh")
    if background
      system("/tmp/tcpdump-#{name}.sh &")
    else
      system("/tmp/tcpdump-#{name}.sh")
    end
  end
end

# From: "/usr/include/linux/sockios.h"
SIOCETHTOOL = 0x8946

# From: "/usr/include/linux/ethtool.h"
ETHTOOL_GSET = 1

# From: "/usr/include/linux/ethtool.h"
class EthtoolCmd < CStruct
  uint32 :cmd
  uint32 :supported
  uint32 :advertising
  uint16 :speed
  uint8  :duplex
  uint8  :port
  uint8  :phy_address
  uint8  :transceiver
  uint8  :autoneg
  uint8  :mdio_support
  uint32 :maxtxpkt
  uint32 :maxrxpkt
  uint16 :speed_hi
  uint8  :eth_tp_mdix
  uint8  :reserved2
  uint32 :lp_advertising
  uint32 :reserved_a0
  uint32 :reserved_a1
end

# From: "/usr/include/linux/ethtool.h"
#define SUPPORTED_10baseT_Half      (1 << 0)
#define SUPPORTED_10baseT_Full      (1 << 1)
#define SUPPORTED_100baseT_Half     (1 << 2)
#define SUPPORTED_100baseT_Full     (1 << 3)
#define SUPPORTED_1000baseT_Half    (1 << 4)
#define SUPPORTED_1000baseT_Full    (1 << 5)
#define SUPPORTED_Autoneg           (1 << 6)
#define SUPPORTED_TP                (1 << 7)
#define SUPPORTED_AUI               (1 << 8)
#define SUPPORTED_MII               (1 << 9)
#define SUPPORTED_FIBRE             (1 << 10)
#define SUPPORTED_BNC               (1 << 11)
#define SUPPORTED_10000baseT_Full   (1 << 12)
#define SUPPORTED_Pause             (1 << 13)
#define SUPPORTED_Asym_Pause        (1 << 14)
#define SUPPORTED_2500baseX_Full    (1 << 15)
#define SUPPORTED_Backplane         (1 << 16)
#define SUPPORTED_1000baseKX_Full   (1 << 17)
#define SUPPORTED_10000baseKX4_Full (1 << 18)
#define SUPPORTED_10000baseKR_Full  (1 << 19)
#define SUPPORTED_10000baseR_FEC    (1 << 20)

def get_supported_speeds(interface)
  ecmd = EthtoolCmd.new
  ecmd.cmd = ETHTOOL_GSET

  ifreq = [interface, ecmd.data].pack("a16p")
  sock = Socket.new(Socket::AF_INET, Socket::SOCK_DGRAM, 0)
  sock.ioctl(SIOCETHTOOL, ifreq)

  rv = ecmd.class.new
  rv.data = ifreq.unpack("a16p")[1]

  speeds = []
  speeds << "10m" if (rv.supported & ((1<<0)|(1<<1)))
  speeds << "100m" if (rv.supported & ((1<<2)|(1<<3)))
  speeds << "1g" if (rv.supported & ((1<<5)|(1<<5)))
  speeds << "10g" if (rv.supported & ((0xf<<17)|(1<<12)))
  speeds
end

crowbar_ohai Mash.new
crowbar_ohai[:switch_config] = Mash.new unless crowbar_ohai[:switch_config]

networks = []
mac_map = {}
bus_found=false
logical_name=""
mac_addr=""
wait=false
Dir.foreach("/sys/class/net") do |entry|
  next if entry =~ /\./
  # We only care about actual physical devices.
  next unless File.exists? "/sys/class/net/#{entry}/device"
  type = File::open("/sys/class/net/#{entry}/type").readline.strip rescue "0"
  if type == "1"
    s1 = File.readlink("/sys/class/net/#{entry}") rescue ""
    spath = File.readlink("/sys/class/net/#{entry}/device") rescue "Unknown"
    spath = s1 if s1 =~ /pci/
    spath = spath.gsub(/.*pci/, "").gsub(/\/net\/.*/, "")

    crowbar_ohai[:detected] = Mash.new unless crowbar_ohai[:detected]
    crowbar_ohai[:detected][:network] = Mash.new unless crowbar_ohai[:detected][:network]
    speeds = get_supported_speeds(entry)
    crowbar_ohai[:detected][:network][entry] = { :path => spath, :speeds => speeds }

    logical_name = entry
    networks << logical_name
    f = File.open("/sys/class/net/#{entry}/address", "r")
    mac_addr = f.gets()
    mac_map[logical_name] = mac_addr.strip
    f.close
    if !File.exists?("/tmp/tcpdump.#{logical_name}.out")
      System.background_time_command(45, true, logical_name, "ifconfig #{logical_name} up ; tcpdump -c 1 -lv -v -i #{logical_name} -a -e -s 1514 ether proto 0x88cc > /tmp/tcpdump.#{logical_name}.out")
      wait=true
    end
  end
end
system("sleep 45") if wait

networks.each do |network|
  sw_port = -1
  line = %x[cat /tmp/tcpdump.#{network}.out | grep "Subtype Interface Name"]
  if line =~ /[\d]+\/[\d]+\/([\d]+)/
    sw_port = $1
  end
  if line =~ /: Unit [\d]+ Port ([\d]+)/
    sw_port = $1
  end
  if line =~ /: [\S]+ [\d]+\/([\d]+)/
    sw_port = $1
  end

  sw_unit = -1
  line = %x[cat /tmp/tcpdump.#{network}.out | grep "Subtype Interface Name"]
  if line =~ /([\d]+)\/[\d]+\/[\d]+/
    sw_unit = $1
  end
  if line =~ /: Unit ([\d]+) Port [\d]+/
    sw_unit = $1
  end

  sw_port_name = nil
  line = %x[cat /tmp/tcpdump.#{network}.out | grep "Subtype Interface Name"]
  if line =~ /: ([\S]+ [\d]+\/[\d]+)/
    sw_port_name = $1
  else
    sw_port_name = "#{sw_unit}/0/#{sw_port}"
  end

  sw_name = -1
  # Using mac for now, but should change to something else later.
  line = %x[cat /tmp/tcpdump.#{network}.out | grep "Subtype MAC address"]
  if line =~ /: (.*) \(oui/
    sw_name = $1
  end

  crowbar_ohai[:switch_config][network] = Mash.new unless crowbar_ohai[:switch_config][network]
  crowbar_ohai[:switch_config][network][:interface] = network
  crowbar_ohai[:switch_config][network][:mac] = mac_map[network].downcase
  crowbar_ohai[:switch_config][network][:switch_name] = sw_name
  crowbar_ohai[:switch_config][network][:switch_port] = sw_port
  crowbar_ohai[:switch_config][network][:switch_port_name] = sw_port_name
  crowbar_ohai[:switch_config][network][:switch_unit] = sw_unit
end

