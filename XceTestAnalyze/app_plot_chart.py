import argparse
from utilities.mysql_connect import \
    find_fail_the_most_frequently, \
    find_take_the_most_time, \
    find_take_the_most_avg_time, \
    find_the_largest_stdev


parser = argparse.ArgumentParser(description='Find the slowest job from XCE Tests log')
parser.add_argument('-d', '--days', type = int, metavar='', default=182, required=False, help = 'last n days')
parser.add_argument('-s', '--size', type = int, metavar='', default=10, required=False, help='top list size')
parser.add_argument('-mff', '--most_fail_frequently', action="store_true", help='Find fail the most frequently')
parser.add_argument('-mt', '--most_time', action="store_true", help='Find take the most of time')
parser.add_argument('-ms', '--most_stdev',action="store_true", help='Find the most of standard deviation')
args = parser.parse_args()

if __name__ == '__main__':

    find_fail_the_most_frequently( args.size, args.days )
    find_take_the_most_time( args.size, args.days )
    find_the_largest_stdev( args.size, args.days )
    find_take_the_most_avg_time( args.size, args.days )

    exit()

    if args.most_fail_frequently: find_fail_the_most_frequently( args.size, args.days )
    if args.most_time: find_take_the_most_time( args.size, args.days )
    if args.most_stdev: find_the_largest_stdev( args.size, args.days )
    # find_take_the_most_avg_time(10, args.days)