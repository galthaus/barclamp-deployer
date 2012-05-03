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

# This recipie is a placeholder for misc. hacks we want to do on every node,
# but that do not really belong with any specific barclamp.

states = [ "ready", "readying", "recovering", "applying" ]
if states.include?(node[:state])
  # Don't waste time with mlocate or updatedb
  %w{mlocate mlocate.cron updatedb}.each do |f|
    file "/etc/cron.daily/#{f}" do
      action :delete
    end
  end
end
