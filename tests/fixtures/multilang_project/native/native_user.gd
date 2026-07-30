extends Node

var native_child := NativeChild.new()

# STALE_NATIVE_TYPE used to be a native implementation but is not registered
# or compiled anymore. A comment must not make its old header reachable.
