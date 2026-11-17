# CasperOS — audio client latency for the Bay Trail SST codec.
#
# Bay Trail's SST path under-runs at the default PulseAudio/PipeWire client
# latency and crackles; 60 ms is comfortably ahead of it and still fine for
# video. This is a generic client setting, not a Wine one: it applies to every
# PulseAudio/PipeWire client on the system.
export PULSE_LATENCY_MSEC=60
