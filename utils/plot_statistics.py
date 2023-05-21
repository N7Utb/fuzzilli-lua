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
last_sample_count = 0
execsPerSec = []
for col in data.columns:
    execsPerSec.append( (int(data[col]["totalSamples"]) - last_sample_count) / 60 )
    last_sample_count = int(data[col]["totalSamples"]) 
data.loc['execsPerSec'] = execsPerSec
print(data)


nautilus_coverage_df = pd.read_csv("./nautilus_coverage.txt")
# nautilus_coverage_df
start_time = min(nautilus_coverage_df['mtime'])
nautilus_coverage_df['mtime'] = nautilus_coverage_df['mtime'].map(lambda x: (x - start_time) / 60)


afl_coverage_df = pd.read_csv("./afl_coverage.txt")
# nautilus_coverage_df
start_time = min(afl_coverage_df['mtime'])
afl_coverage_df['mtime'] = afl_coverage_df['mtime'].map(lambda x: (x - start_time) / 60)
afl_coverage_df = afl_coverage_df[afl_coverage_df['mtime'] <= 693]

w, h = figaspect(0.618)  # golden ratio
fig, ax = plt.subplots(figsize=(w, h))
for item in ([ax.title, ax.xaxis.label, ax.yaxis.label]):
    item.set_fontsize(16)
for item in (ax.get_xticklabels()):
    item.set_fontsize(16)
    item.set_rotation(45)
for item in (ax.get_yticklabels()):
    item.set_fontsize(16)

# print(nautilus_coverage_df['edges'])
ax.plot([0] + list(nautilus_coverage_df['mtime'].values), [0] + list(nautilus_coverage_df['edges'].values), color="g", linewidth=2, solid_capstyle="butt", zorder=4, ms=6, label="Nautilus")

ax.plot([0] + list(afl_coverage_df['mtime'].values), [0] + list(afl_coverage_df['edges'].values), color="y", linewidth=2, solid_capstyle="butt", zorder=4, ms=6, label="AFL")
# ax.set_yticks(np.linspace(0,3000,100))
# print()
ax.plot([0] + list(data.keys().values), [0] + list(map(lambda x: int(x), list(data.loc['foundEdges',:].values))), color="r", linewidth=2, solid_capstyle="butt", zorder=4, ms=6,label="MAGGOT")

ax.set_xlim(xmin=0)
ax.set_ylim(ymin=0)
ax.set(xlabel="Time(Min)", ylabel="Edges")
plt.legend()    # 图例
plt.tight_layout()
# plt.show()
plt.savefig(args.output+'/'+"coverage"+'.png')
plt.clf()
plt.close(fig)



nautilus_correctness_df = pd.read_csv("./nautilus_correctness.txt")
nautilus_correctness_df['correctness'] = nautilus_correctness_df.apply(lambda x: x['success_count'] / (x['success_count'] + x['fail_count']),axis = 1)



print(nautilus_correctness_df)
# box = sns.boxplot(ax=ax,y=data.loc['correctnessRate',:], orient="v", fliersize=0,
#                     dodge=False)
# ax.set_xticks

# ax.set_xticklabels(['Fuzzilli_Lua', "Nautilus"])
fig, ax = plt.subplots(figsize=(w, h))
for item in ([ax.title, ax.xaxis.label, ax.yaxis.label]):
    item.set_fontsize(16)
for item in (ax.get_xticklabels()):
    item.set_fontsize(16)
    # item.set_rotation(45)
for item in (ax.get_yticklabels()):
    item.set_fontsize(16)
print(pd.concat([data.transpose()['correctnessRate'],nautilus_correctness_df['correctness']],axis=1))
box = sns.violinplot(ax=ax,data=pd.concat([data.transpose()['correctnessRate'],nautilus_correctness_df['correctness']],axis=1), orient="v", fliersize=0,
                    dodge=False,width=0.4,palette="YlGnBu")
plt.setp(ax, xticks=[0,1],xticklabels=['MAGGOT', 'Nautilus'])
plt.ylabel("Correctness(%)")

plt.savefig(args.output+'/'+"Correctness"+'.png')
# plt.show()
plt.clf()
plt.close(fig)



nautilus_df = pd.read_csv("./correctness.txt")
nautilus_df['correctness'] = nautilus_df.apply(lambda x: x['success_count'] / (x['success_count'] + x['fail_count']),axis = 1)
last_sample_count = 0
execsPerSec = []
for index, row in nautilus_df.iterrows():
    execsPerSec.append( (row['success_count'] + row['fail_count'] - last_sample_count))
    if (row['success_count'] + row['fail_count'] - last_sample_count) < 0:
        print(index)

    last_sample_count = row['success_count'] + row['fail_count']
    
nautilus_df['execsPerSec'] = execsPerSec

fig, ax = plt.subplots(figsize=(w, h))
for item in ([ax.title, ax.xaxis.label, ax.yaxis.label]):
    item.set_fontsize(16)
for item in (ax.get_xticklabels()):
    item.set_fontsize(16)
    # item.set_rotation(45)
for item in (ax.get_yticklabels()):
    item.set_fontsize(16)

print(pd.concat([data.transpose()['execsPerSec'],nautilus_df['execsPerSec']],axis=1,ignore_index=True))
box = sns.boxplot(ax=ax,data=pd.concat([data.transpose()['execsPerSec'],nautilus_df['execsPerSec']],axis=1,ignore_index=True), orient="v", fliersize=2,
                    dodge=False,width=0.4,palette="YlGnBu",showmeans=True,  linewidth=1,            meanprops={'marker':'o','markerfacecolor':'white', 'markeredgecolor':'black','markersize':'8'})
plt.setp(ax, xticks=[0,1],xticklabels=['MAGGOT', 'Nautilus'])
plt.ylabel("Execution Speed(execs/s)")

plt.savefig(args.output+'/'+"execution_speed"+'.png')
plt.clf()
plt.close(fig)
