# gpu-pvclust
gputools + pvclust

uses gputools to accelerate pvclust

use at own risk, 
code copied from [pvclust](http://stat.sys.i.kyoto-u.ac.jp/prog/pvclust) and [gputools](https://github.com/nullsatz/gputools)

# requirements
NVIDIA gpu with compute >= 2.0
CUDA 
R library gputools

# usage

source(functions.R)
gpu.pvclust.parallel(some_matrix)


