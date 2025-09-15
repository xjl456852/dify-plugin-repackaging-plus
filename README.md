## dify插件离线打包脚本

dify插件安装本身需要外网下载依赖,如果在纯内网环境中安装,则无法下载插件依赖.

本项目可以将插件打包为离线包,支持纯内网环境中本地离线安装.

## 功能

- 支持Centos/Ubuntu/Debian等系统
- 支持amd64架构和arm64架构打包
- 支持amd64跨架构到arm64打包



## 插件离线打包方法及示例

## Centos/Ubuntu系统 amd64和arm64打包方法

```shell
#进入到程序目录,例如用wsl2进入目标位置
cd /mnt/h/code/dify-plugin-repackaging-plus
# 打包命令
./plugin_repackaging.sh local 插件名
```

例如:

```shell
./plugin_repackaging.sh local hjlarry-database_0.0.6.difypkg
```



## Centos/Ubuntu系统 amd64跨架构打包arm64方法

当前系统为arm64架构,需要打包arm64的离线插件包

```shell
#进入到程序目录,例如用wsl2进入目标位置
cd /mnt/h/code/dify-plugin-repackaging-plus
# 打包命令
./plugin_repackaging_amd64_to_arm64.sh local 插件名
```

例如:

```shell
./plugin_repackaging_amd64_to_arm64.sh local hjlarry-database_0.0.6.difypkg
```

