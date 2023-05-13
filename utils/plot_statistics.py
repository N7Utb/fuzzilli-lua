import argparse,os,json
import seaborn as sns
import matplotlib.pyplot as plt
import pandas as pd
import numpy as np
from matplotlib.figure import figaspect
import time
parser = argparse.ArgumentParser()
parser.add_argument("-i","--input",required=True,type=str)
parser.add_argument("-o","--output",required=True,type=str)
parser.add_argument("--interval",required=True,type=int)
args = parser.parse_args()



assert(os.path.isdir(args.input))
assert(os.path.isdir(args.output))
fuzz_data = {}
for jsonfile in os.listdir(args.input):
    if jsonfile.endswith('.json'):
        json_path = os.path.join(args.input,jsonfile)
        with open(json_path,"r") as f:
            jsondata = json.load(f)
            jsondata.pop('numChildNodes', "123")
            # fuzz_data[jsonfile.split('.')[0]] = list(jsondata.values())
            fuzz_data[int(time.mktime(time.strptime(jsonfile.split('.')[0], "%Y%m%d%H%M%S")))] = jsondata


data = pd.DataFrame(data=fuzz_data)
data = data.sort_index(axis=1)
start_time = min(data.keys()) - args.interval
data = data.set_axis(data.keys().map(lambda x: (x - start_time) // 60), axis=1)
data.drop(data.columns[[-1,]], axis=1, inplace=True)
print(data)

w, h = figaspect(0.618)  # golden ratio
fig, ax = plt.subplots(figsize=(w, h))
for item in ([ax.title, ax.xaxis.label, ax.yaxis.label]):
    item.set_fontsize(16)
for item in (ax.get_xticklabels()):
    item.set_fontsize(16)
    # item.set_rotation(45)
for item in (ax.get_yticklabels()):
    item.set_fontsize(16)
ax.plot([0] + list(data.keys().values), [0] + list(data.loc['coverage',:].values), color="k", linewidth=5, solid_capstyle="butt", zorder=4, ms=6)
ax.set_ylim(ymin=0)
ax.set_xlim(xmin=0)
ax.set(xlabel="Time", ylabel="Coverage(%)",title="Coverage")
plt.savefig(args.output+'/'+"coverage"+'.png')
plt.clf()
plt.close(fig)


fig, ax = plt.subplots(figsize=(w, h))
for item in ([ax.title, ax.xaxis.label, ax.yaxis.label]):
    item.set_fontsize(16)
for item in (ax.get_xticklabels()):
    item.set_fontsize(16)
    # item.set_rotation(45)
for item in (ax.get_yticklabels()):
    item.set_fontsize(16)
print(data.loc[['correctnessRate','execsPerSecond'],:])
# box = sns.boxplot(ax=ax,y=data.loc['correctnessRate',:], orient="v", fliersize=0,
#                     dodge=False)
box = sns.boxplot(ax=ax,data=data.loc[['correctnessRate','execsPerSecond'],:].transpose(), orient="v", fliersize=0,
                    dodge=False)
plt.show()