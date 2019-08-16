from enum import IntEnum
class Status(IntEnum):
    OK = 0
    NO_CREDIT_HISTORY = 1
    NO_RUNNING_CLUSTER = 2
    NO_STACK = 4
    STACK_NOT_FOUND = 5
    CLUSTER_NOT_READY = 6
    S3_BUCKET_NOT_EXIST = 7