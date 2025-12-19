# SchemaQuench
![.Build validate](https://github.com/Schema-Smith/SchemaSmithyFree/actions/workflows/continuous-integration.yml/badge.svg)

[English](README.md) | 简体中文

SchemaQuench 是一个基于状态的数据库迁移工具，设计理念明确。类似于 HashiCorp 的 Terraform，SchemaQuench 接受一组数据库的期望最终状态（以元数据形式），并将应用的服务器转换为匹配该状态。

## 为什么不直接使用迁移脚本来维护服务器？

迁移脚本展示了数据库随时间的演变过程。虽然这对于了解数据库是如何发展的很有用，但你无法直接知道数据库此时此刻的当前状态。这就是基于状态方法的优越之处。

在最后一次发布时，元数据仓库的状态准确代表了服务器应有的状态。采用这种方法，可以像对待其他生产代码一样对待 SQL Server 代码，保证它们始终保持同步。

## 技术说明

> 目标框架: net9.0, net481
> 
> IDE: Visual Studio 2022, JetBrains Rider
> 
> MSSQL Server: 当前针对 2019-CU27-ubuntu-20.04 进行测试。SQL Server 2014（兼容级别 120）是支持的最低版本，包括基于 XML 的表定义和用于 quench 操作的数据有效负载。

## 快速开始

如果你安装了 Docker，可以在项目根目录运行：

```bash
docker compose build
docker compose up
```

这将把 [测试产品](TestProducts/ValidProduct/Product.json) 应用到一个 Linux SQL Server 2019 Docker 容器。你可以使用 [.env](.env) 文件中定义的用户名、密码和端口，连接到 localhost 上的服务器。

## 附加资源

- 更多示例，请查看我们的 [演示仓库](https://github.com/Schema-Smith/SchemaSmithDemos)。
- 查看我们的 [wiki](https://github.com/Schema-Smith/SchemaSmithyFree/wiki)，了解这些工具如何使 SQL Server 架构部署变得轻松的文档。
- [新手入门指南](docs/GETTING_STARTED.zh-CN.md) - 适合初次使用的开发者
- [工具使用指南](docs/TOOLS_GUIDE.zh-CN.md) - SchemaQuench、SchemaTongs 和 DataTongs 的详细使用说明

## 贡献

欢迎贡献！请查看 [贡献指南](CONTRIBUTING.md) 了解如何参与项目开发。

## 许可证

详见 [LICENSE](LICENSE) 文件。
