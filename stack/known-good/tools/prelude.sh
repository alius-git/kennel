# Kennel issue #13 -- the source chain every container shell needs.
# Non-interactive `docker exec ... bash -c` never reads /root/.bashrc (it
# returns early on [ -z "$PS1" ]), so everything .bashrc would have set has to
# be set here explicitly.
source /opt/ros/humble/setup.bash
[ -f /root/unitree_ros2/install/setup.bash ] && source /root/unitree_ros2/install/setup.bash
source /root/ros2_ws/install/setup.bash
# Drake env, normally from .bashrc.
export PATH="/opt/drake/bin:${PATH}"
export PYTHONPATH="/opt/drake/lib/python3.10/site-packages:${PYTHONPATH}"
export LD_LIBRARY_PATH="/opt/drake/lib:${LD_LIBRARY_PATH}"
export ROS_PACKAGE_PATH="/root/ros2_ws/src"
# DDS + domain. MUST be identical in every shell or the nodes never meet.
# setup_ulab_workspace.bash is the SIM setup despite its name (fastrtps,
# ROS_DOMAIN_ID=100). setup_go2_workspace.bash (`sg`) is the REAL-hardware
# path and pins CycloneDDS to NIC enp0s31f6, which does not exist here.
source /root/setup_ulab_workspace.bash
cd /root/ros2_ws
