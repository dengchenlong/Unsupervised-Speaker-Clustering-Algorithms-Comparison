该配方基于AMI mix-headset数据集分别使用i-vectors、x-vectors和其他深度学习方法实现了说话人分
割聚类。此外，我还演示了不同聚类方法的使用，包括AHC、Spectrum和VBx。

## 关于数据集注释和分割

我使用了官方的`AMI_public_manual_1.6.2`注释来生成参考RTTM文件。注释包含`word`和
`vocal sound`标签，后者包含大量类似音效的声音（主要是笑声，掌声等等）。为了实现【标准评估】，
我忽略了所有这种声音，只考虑`word`注释。我合并了相邻的没有停顿的语段。

train/dev/test分割来自官方的AMI完整语料库分区。

想了解更多详情，请参阅后文中的第四部分:`https://arxiv.org/pdf/2012.14952.pdf`

数据集分割和参考RTTM文件可在这里获取:
`https://github.com/BUTSpeechFIT/AMI-diarization-setup`

## 结果

下面展示使用已知的SAD和无重叠检测的结果。开发集和测试集分别包含13.5%和14.6%的说话人重叠，这导
致了语音缺失。使用已知的SAD后，误报率为0%。DER等于语音缺失率（=重叠率）、误报率（=0）和说话人
混淆率（SE）之和。

| Method   | Dev SE | Dev DER | Test SE | Test DER |
|----------|--------|---------|---------|----------|
| AHC      | 7.2    | 20.7    | 9.7     | 24.3     |
| Spectral | 6.2    | 19.7    | 5.6     | 20.2     |
| VBx      | 6.0    | 19.5    | 8.4     | 23.0     |
