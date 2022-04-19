#!/usr/bin/env bash

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

# 配置参数。
stage=0
diarizer_stage=0  # 1: 提取嵌入码; 2: 计算相似度; 3: 聚类。
nj=10
decode_nj=12
model_dir=exp/xvector_nnet_1a  # 嵌入码提取模型所在路径。
train_cmd="run.pl"
test_sets="dev test"
AMI_DIR=/data/dcl/ami-mix-headset
score_type=plda  # plda/cossim
diarizer_type=ahc  # ahc/spectral/vbx，vbx只用于x-vector。
threshold_ahc=0.1  # AHC聚类阈值，默认为0.1。
min_neighbors=3  # 谱聚类参数，默认为3。
threshold_vbx=0.1  # VBx参数，默认为0.1。
loop_prob=0.5  # VBx参数，默认为0.5。
fa=0.05  # VBx参数，默认为0.05。
fb=1  # VBx参数，默认为1。
target_energy=0.1  # PLDA参数，默认为0.1。
window_diar=1.5  # 默认为1.5。
period_diar=0.75  # 默认为0.75。
min_segment_diar=0.5  # 默认为0.5。
apply_cmn_when_extracting=false
hard_min=true
window=3.0  # 默认为3.0。
period=10.0  # 默认为10.0。
min_segment=1.5  # 默认为1.5。
# 配置参数。

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
    steps/make_mfcc.sh --mfcc-config conf/mfcc_hires.conf --nj 15 --cmd "$train_cmd" data/"$dataset" exp/"$dataset"_mfcc exp/"$dataset"_mfcc
    utils/fix_data_dir.sh data/"$dataset"
  done
fi

if [ $stage -le 4 ]; then
  echo "$0: 准备AMI训练数据用于训练PLDA模型。"
  # 使用滑动窗口进行CMVN并将特征写入硬盘。
  local/nnet3/xvector/prepare_feats.sh --nj 20 --cmd "$train_cmd" \
    data/train data/train_cmn exp/train_cmn
  utils/fix_data_dir.sh data/train_cmn
fi

if [ $stage -le 5 ]; then
  echo "$0: 提取PLDA训练数据的x-vector嵌入码。"
  diarization/nnet3/xvector/extract_xvectors.sh --cmd "$train_cmd" --nj 12 \
    --window $window --period $period --min-segment $min_segment --apply-cmn $apply_cmn_when_extracting --hard-min $hard_min \
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
    local/diarize.sh --nj $nj --cmd "$train_cmd" --stage $diarizer_stage \
      --embedding_type xvector --score_type $score_type --cluster_type $diarizer_type \
      --threshold_ahc $threshold_ahc --threshold_vbx $threshold_vbx --target_energy $target_energy --min_neighbors $min_neighbors \
      --window $window_diar --period $period_diar --min_segment $min_segment_diar \
      --loop_prob $loop_prob --fa $fa --fb $fb --apply_cmn $apply_cmn_when_extracting \
      $model_dir data/"${datadir}" exp/"${datadir}"_"${diarizer_type}"_xvector

    # 使用md-eval.pl评估RTTM
    rttm_affix=
    if [ $diarizer_type == "vbx" ]; then
      rttm_affix=".vb"
    fi
    md-eval.pl -r "$ref_rttm" -s exp/"${datadir}"_"${diarizer_type}"_xvector/rttm${rttm_affix} > result_xvector_"$score_type"_"$diarizer_type"_"$datadir"
  done
fi
