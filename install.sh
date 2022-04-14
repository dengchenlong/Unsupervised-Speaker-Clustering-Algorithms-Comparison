#!/usr/bin/env bash

# 根据自己情况修改路径。KALDI_ROOT是安装kaldi的路径，ami_dir是ami语料库的存储路径，
# 其子目录应为EN2001a、EN2001b等会议目录。
export KALDI_ROOT=/home/ubuntu/kaldi
ami_dir=/data/dcl/ami_mix_headset

# 创建软链接
ln -s ${KALDI_ROOT}/egs/callhome_diarization/v1/diarization/ scripts/diarization
ln -s ${KALDI_ROOT}/egs/sre08/v1/sid scripts/sid
ln -s ${KALDI_ROOT}/egs/wsj/s5/steps scripts/steps
ln -s ${KALDI_ROOT}/egs/wsj/s5/utils scripts/utils
ln -s ${KALDI_ROOT} kaldi
ln -s $ami_dir ami_mix_headset
