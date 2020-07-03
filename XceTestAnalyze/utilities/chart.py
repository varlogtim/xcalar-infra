import numpy as np
import matplotlib as mp
import matplotlib.pyplot as plt

def bar_char(tasks, volumn, xlabel='', ylabel='', title=''):
    x=np.arange(len(tasks))                     #產生X軸座標序列
    plt.bar(x, volumn, tick_label=tasks, color=(0.2, 0.4, 0.6 ))        #繪製長條圖
    plt.title(title)                            #設定圖形標題
    plt.xlabel(xlabel)                          #設定X軸標籤
    plt.ylabel(ylabel)                          #設定Y軸標籤
    plt.xticks(rotation=90)
    plt.show()


def barh(tasks, nums, xlabel='', ylabel='', title=''):
    a_vals = tasks
    b_vals = nums
    ind = np.arange(len(tasks))
    width = 0.5

    # Set the colors
    colors = ['b', 'g', 'r', 'c', 'm', 'y', 'g']

    def autolabel(bars):
        # attach some text labels
        for i, bar in enumerate(bars):
            width = bar.get_width()
            # ax.text(width * 0.9,  i + .25, str(width), color='blue', fontweight='bold')
            ax.text(width + 10,
                    bar.get_y() + bar.get_height() / 2,
                    '%d' % int(width),
                    ha='right', va='center')

    # make the plots
    fig, ax = plt.subplots()
    a = ax.barh(ind, a_vals, width, color=colors)  # plot a vals
    b = ax.barh(ind + width, b_vals, width, color=colors, alpha=0.5)  # plot b vals
    ax.set_yticks(ind + width)  # position axis ticks
    ax.set_yticklabels(tasks)  # set them to the names
    ax.legend((a[0], b[0]), ['a', 'b'], loc='center right')

    autolabel(a)
    # autolabel(b)

    plt.show()


def horizontal_bar_chart(tasks, nums, xlabel='', ylabel='', title=''):
    print(title)
    data_normalizer = mp.colors.Normalize()
    color_map = mp.colors.LinearSegmentedColormap(
        "my_map",
        {
            "red": [(0, 1.0, 1.0),
                    (1.0, .5, .5)],
            "green": [(0, 0.5, 0.5),
                      (1.0, 0, 0)],
            "blue": [(0, 0.50, 0.5),
                     (1.0, 0, 0)]
        }
    )


    # tip text
    # Set the colors
    colors = ['b', 'g', 'r', 'c', 'm', 'y', 'g']
    def autolabel(bars):
        # attach some text labels
        for bar in bars:
            width = bar.get_width()
            ax.text(width + 6, bar.get_y() + bar.get_height() / 2,
                    '%d' % int(width),
                    ha='right', va='center')
    #
    plt.rcdefaults()
    fig, ax = plt.subplots()

    # Example data
    tasks = tasks
    y_pos = np.arange(len(tasks))
    performance = nums
    error = np.random.rand(len(tasks))

    a= ax.barh(y_pos, performance, align='center', color=colors, alpha=0.5)
    ax.set_yticks(y_pos)
    short_name_tasks = []
    for tsk in tasks:
        short_name_tasks.append( tsk.split('::')[-1] )
    ax.set_yticklabels(short_name_tasks)
    ax.invert_yaxis()           # labels read top-to-bottom
    ax.set_xlabel(xlabel)
    ax.set_title(title)
    #
    ax.spines['right'].set_visible(False)
    ax.spines['top'].set_visible(False)
    ax.patch.set_facecolor('#FFFFFF')
    ax.spines['bottom'].set_color('#CCCCCC')
    ax.spines['bottom'].set_linewidth(1)
    ax.spines['left'].set_color('#CCCCCC')
    ax.spines['left'].set_linewidth(1)
    autolabel(a)

    plt.show()
    # plt.savefig(f'{title}.png')


if __name__ == '__main__':
    tasks = ['James Soong', 'Korea Fish', 'Tsai Ing-Wen']
    volumn = [608590, 5522119, 8170231]
    bar_char( volumn, tasks )