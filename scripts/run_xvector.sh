#!/usr/bin/env bash
# Copyright   2022   Nankai University (Author: Chenlong Deng)
# Apache 2.0.
#
# 此配方对AMI语料库中的mix-headset录音进行说话人分割聚类。
# x-vector模型是在有仿真RIR文件的VoxCeleb v2语料库上训练的。
# 这个配方使用了已知的SAD。
# 此配方演示了使用x-vector和聚类方法（AHC、VBx、谱聚类）进行说话人分割聚类。

# 此配方不提供训练x-vector模型的脚本。你可以从如下网站获取预训练好的模型：
# http://kaldi-asr.org/models/12/0012_diarization_v1.tar.gz
# 下载后解压。

. ./cmd.sh
. ./path.sh
set -euo pipefail

stage=7
diarizer_stage=3  # 1: 提取嵌入码; 2: 计算相似度; 3: 聚类
nj=10
decode_nj=12

model_dir=exp/xvector_nnet_1a  # Where xvector extractor or ivector extractor locates
train_cmd="run.pl"
test_sets="dev test"
AMI_DIR=/data/dcl/ami-mix-headset

score_type=plda  # plda/cossim
diarizer_type=vbx  # ahc/spectral/vbx

. utils/parse_options.sh

# 下载AMI语料库，需要14GB左右，注意脚本中的数据集存放路径。
if [ $stage -le 1 ]; then
  [ -d $AMI_DIR ] || local/ami_download.sh
fi

# 准备数据文件存放目录。
if [ $stage -le 2 ]; then
  # 下载数据集分割和参考。
  if ! [ -d AMI-diarization-setup ]; then
    git clone https://github.com/BUTSpeechFIT/AMI-diarization-setup
  fi

  for dataset in train $test_sets; do
    echo "$0: preparing $dataset set.."
    mkdir -p data/"$dataset"
    # 从会议lists和已知的SAD标签准备wav.scp和segments文件。
    # 将所有参考RTTM文件合到一个文件中。
    local/prepare_data.py --sad-labels-dir AMI-diarization-setup/only_words/labs/"${dataset}" \
      AMI-diarization-setup/lists/"${dataset}".meetings.txt \
      $AMI_DIR data/"$dataset"
    cat AMI-diarization-setup/only_words/rttms/"${dataset}"/*.rttm \
      > data/"${dataset}"/rttm.annotation

    awk '{print $1,$2}' data/"$dataset"/segments > data/"$dataset"/utt2spk
    utils/utt2spk_to_spk2utt.pl data/"$dataset"/utt2spk > data/"$dataset"/spk2utt
    utils/fix_data_dir.sh data/"$dataset"
  done
fi

# 提取MFCC音频特征。
if [ $stage -le 3 ]; then
  for dataset in train $test_sets; do
    steps/make_mfcc.sh --mfcc-config conf/mfcc.conf --nj 15 --cmd "$train_cmd" data/"$dataset" exp/"$dataset"_mfcc exp/"$dataset"_mfcc
    utils/fix_data_dir.sh data/"$dataset"
  done
fi

if [ $stage -le 4 ]; then
  echo "$0: preparing a AMI training data to train PLDA model"
  # 使用滑动窗口进行CMVN并将特征写入硬盘。
  local/nnet3/xvector/prepare_feats.sh --nj 20 --cmd "$train_cmd" \
    data/train data/train_cmn exp/train_cmn
  utils/fix_data_dir.sh data/train_cmn
fi

if [ $stage -le 5 ]; then
  echo "$0: extracting x-vector for PLDA training data"
  diarization/nnet3/xvector/extract_xvectors.sh --cmd "$train_cmd" --nj 12 \
    --window 3.0 --period 10.0 --min-segment 1.5 --apply-cmn false --hard-min true \
    $model_dir data/train_cmn exp/train_xvector
fi

# 训练PLDA模型。
if [ $stage -le 6 ]; then
  echo "$0: training PLDA model"
  # 计算平均矢量使待评估矢量居中。
  $train_cmd exp/train_plda_xvector/log/compute_mean.log \
    ivector-mean scp:exp/train_xvector/xvector.scp \
    exp/train_plda_xvector/mean.vec || exit 1;

  # 训练PLDA模型
  $train_cmd exp/train_plda_xvector/log/plda.log \
    ivector-compute-plda ark:exp/train_xvector/spk2utt \
    "ark:ivector-subtract-global-mean scp:exp/train_xvector/xvector.scp ark:- |\
     transform-vec exp/train_xvector/transform.mat ark:- ark:- |\
      ivector-normalize-length ark:-  ark:- |" \
    exp/train_plda_xvector/plda || exit 1;
  
  cp exp/train_plda_xvector/mean.vec $model_dir/
  cp exp/train_xvector/transform.mat $model_dir/
  cp exp/train_plda_xvector/plda $model_dir/
fi

if [ $stage -le 7 ]; then
  for datadir in ${test_sets}; do
    ref_rttm=data/${datadir}/rttm.annotation

    diarize_nj=$(wc -l < "data/$datadir/wav.scp")
    nj=$((decode_nj>diarize_nj ? diarize_nj : decode_nj))
    # local/diarize_xvector_${score_type}_${diarizer_type}.sh --nj $nj --cmd "$train_cmd" --stage $diarizer_stage \
    #   $model_dir data/"${datadir}" exp/"${datadir}"_"${diarizer_type}"_xvector
    local/diarize.sh --nj $nj --cmd "$train_cmd" --stage $diarizer_stage \
      --embedding_type xvector --score_type $score_type --cluster_type $diarizer_type \
      $model_dir data/"${datadir}" exp/"${datadir}"_"${diarizer_type}"_xvector

    # 使用md-eval.pl评估RTTM
    rttm_affix=
    if [ $diarizer_type == "vbx" ]; then
      rttm_affix=".vb"
    fi
    md-eval.pl -r "$ref_rttm" -s exp/"${datadir}"_"${diarizer_type}"_xvector/rttm${rttm_affix} > result_xvector_"$score_type"_"$diarizer_type"_"$datadir"
  done
fi
