from enum import IntEnum
class Status(IntEnum):
    OK = 0
    NO_CREDIT_HISTORY = 1
    NO_RUNNING_CLUSTER = 2
    NO_STACK_FOUND = 3
    CLUSTER_NOT_READY = 4