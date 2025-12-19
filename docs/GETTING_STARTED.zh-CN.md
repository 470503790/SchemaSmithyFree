# 新手入门指南

[English](GETTING_STARTED.md) | 简体中文

欢迎使用 SchemaSmithyFree！本指南将帮助你快速上手，了解如何使用这套工具来管理 SQL Server 数据库架构。

## 目录

- [什么是 SchemaSmithyFree？](#什么是-schemasmithyfree)
- [环境要求](#环境要求)
- [安装和设置](#安装和设置)
- [核心概念](#核心概念)
- [第一个示例项目](#第一个示例项目)
- [常见问题](#常见问题)

## 什么是 SchemaSmithyFree？

SchemaSmithyFree 是一套用于管理 SQL Server 数据库架构的工具集，包括三个主要工具：

1. **SchemaQuench** - 数据库迁移工具，将数据库转换为期望的状态
2. **SchemaTongs** - 模板生成工具，从现有数据库生成元数据
3. **DataTongs** - 数据迁移工具，处理数据的导入导出

这些工具采用**基于状态**的方法，而不是传统的迁移脚本方法。这意味着你定义数据库应该是什么样子，工具会自动计算并执行必要的更改。

## 环境要求

在开始之前，确保你的开发环境满足以下要求：

### 必需组件
- **.NET SDK**: 需要 .NET 9.0 或 .NET Framework 4.8.1
- **SQL Server**: SQL Server 2014 或更高版本（兼容级别 120+）
- **IDE**（可选但推荐）：
  - Visual Studio 2022
  - JetBrains Rider
  - Visual Studio Code

### Docker 快速启动（推荐）
如果你已安装 Docker，可以跳过大部分手动设置：
- Docker Desktop（Windows/Mac）
- Docker Engine（Linux）

## 安装和设置

### 方法 1: 使用 Docker（推荐新手）

这是最简单的入门方法：

1. **克隆仓库**
   ```bash
   git clone https://github.com/Schema-Smith/SchemaSmithyFree.git
   cd SchemaSmithyFree
   ```

2. **启动 Docker 容器**
   ```bash
   docker compose build
   docker compose up
   ```

3. **连接到数据库**
   - 服务器: `localhost`
   - 用户名: 查看 `.env` 文件
   - 密码: 查看 `.env` 文件
   - 端口: 查看 `.env` 文件（默认通常是 1433）

4. **验证安装**
   - 使用 SQL Server Management Studio (SSMS) 或 Azure Data Studio 连接
   - 你应该能看到测试数据库和相关的表、存储过程等对象

### 方法 2: 本地构建

如果你想从源码构建：

1. **克隆仓库**
   ```bash
   git clone https://github.com/Schema-Smith/SchemaSmithyFree.git
   cd SchemaSmithyFree
   ```

2. **恢复依赖**
   ```bash
   dotnet restore SchemaSmithyFree.sln
   ```

3. **构建项目**
   ```bash
   dotnet build SchemaSmithyFree.sln --configuration Release
   ```

4. **运行工具**
   ```bash
   # 运行 SchemaQuench
   dotnet run --project SchemaQuench/SchemaQuench.csproj
   
   # 运行 SchemaTongs
   dotnet run --project SchemaTongs/SchemaTongs.csproj
   
   # 运行 DataTongs
   dotnet run --project DataTongs/DataTongs.csproj
   ```

## 核心概念

在深入使用之前，了解以下核心概念很重要：

### 产品 (Product)
"产品"是一个包含数据库架构定义的目录结构。一个产品可以包含：
- 一个或多个数据库模板
- 数据库对象定义（表、视图、存储过程等）
- 迁移脚本
- 数据有效负载

产品结构示例：
```
MyProduct/
├── Product.json          # 产品配置文件
└── Templates/
    ├── Main/             # 主数据库模板
    │   ├── Template.json
    │   ├── Tables/
    │   ├── Procedures/
    │   ├── Views/
    │   └── Functions/
    └── Secondary/        # 次要数据库模板（可选）
        ├── Template.json
        └── ...
```

### 模板 (Template)
模板定义单个数据库的架构。它包含：
- 表定义（JSON 格式）
- 存储过程、函数、视图（SQL 文件）
- 架构、数据类型、全文索引等
- 迁移脚本（Before/After）

### 基于状态 vs 基于迁移

**传统的基于迁移方法：**
```
初始状态 → 迁移1 → 迁移2 → 迁移3 → 当前状态
```
- 必须按顺序运行所有迁移
- 难以知道当前的确切状态
- 迁移可能会冲突或失败

**SchemaQuench 的基于状态方法：**
```
定义的期望状态 → SchemaQuench 分析差异 → 应用更改 → 当前状态 = 期望状态
```
- 定义想要的最终状态
- 工具自动计算所需的更改
- 元数据始终反映当前状态

## 第一个示例项目

让我们创建一个简单的数据库架构并使用 SchemaQuench 部署它。

### 步骤 1: 检查测试产品

项目包含一个测试产品，可以作为参考：

```bash
cd TestProducts/ValidProduct
```

查看 `Product.json` 文件：
```json
{
  "Product": "ValidProduct",
  "Version": "1.0.0",
  "Templates": [
    {
      "TemplateName": "Main",
      "TemplateVersion": "1.0.0"
    }
  ]
}
```

### 步骤 2: 查看模板结构

检查 `Templates/Main/Template.json`：
```json
{
  "TemplateName": "Main",
  "DatabaseName": "MainDatabase",
  "Version": "1.0.0"
}
```

### 步骤 3: 查看表定义

表使用 JSON 格式定义。查看 `Templates/Main/Tables/` 目录下的示例：

```json
{
  "TableName": "MyTable",
  "Columns": [
    {
      "ColumnName": "Id",
      "DataType": "int",
      "IsNullable": false,
      "IsPrimaryKey": true,
      "IsIdentity": true
    },
    {
      "ColumnName": "Name",
      "DataType": "nvarchar(100)",
      "IsNullable": false
    }
  ]
}
```

### 步骤 4: 使用 Docker 运行示例

如果已启动 Docker：
```bash
docker compose up
```

这将：
1. 启动 SQL Server 容器
2. 运行 SchemaQuench
3. 应用 ValidProduct 到数据库
4. 显示进度和结果

### 步骤 5: 验证结果

连接到数据库并验证：
```sql
-- 查看创建的数据库
SELECT name FROM sys.databases WHERE name LIKE '%Main%';

-- 查看表
USE MainDatabase;
SELECT * FROM sys.tables;

-- 查看存储过程
SELECT * FROM sys.procedures;
```

### 步骤 6: 修改和重新应用

尝试修改模板：
1. 编辑表定义，添加新列
2. 重新运行 `docker compose up`
3. SchemaQuench 将检测差异并仅应用更改

## 常见问题

### Q: SchemaQuench 与其他数据库迁移工具有什么不同？

**A:** SchemaQuench 使用基于状态的方法，而不是传统的迁移脚本。你定义数据库应该是什么样子，工具会自动计算需要执行的更改。这类似于 Terraform 管理基础设施的方式。

### Q: 我需要编写 SQL 迁移脚本吗？

**A:** 对于大多数架构更改，不需要！你只需更新 JSON 定义和 SQL 对象文件，SchemaQuench 会自动生成必要的更改。但是，对于复杂的数据转换，你可以提供自定义迁移脚本（Before/After）。

### Q: 如何处理现有数据库？

**A:** 使用 **SchemaTongs** 从现有数据库生成元数据：
```bash
dotnet run --project SchemaTongs/SchemaTongs.csproj
```
这将创建一个产品结构，反映你现有数据库的当前状态。

### Q: 可以管理多个数据库吗？

**A:** 可以！一个产品可以包含多个模板，每个模板代表一个数据库。在 `Product.json` 中定义它们：
```json
{
  "Product": "MyProduct",
  "Templates": [
    {"TemplateName": "Database1"},
    {"TemplateName": "Database2"},
    {"TemplateName": "Database3"}
  ]
}
```

### Q: 如何处理敏感数据或连接字符串？

**A:** 使用 `appsettings.json` 和用户机密。工具支持 .NET 的配置系统：
- 本地开发：使用用户机密（`dotnet user-secrets`）
- 生产环境：使用环境变量或安全的配置管理

### Q: 支持哪些 SQL Server 版本？

**A:** 
- **最低版本**: SQL Server 2014（兼容级别 120）
- **测试版本**: SQL Server 2019
- **支持**: SQL Server 2014, 2016, 2017, 2019, 2022

### Q: 可以回滚更改吗？

**A:** 由于 SchemaQuench 是基于状态的，"回滚"意味着将元数据恢复到之前的版本并重新运行 SchemaQuench。使用 Git 等版本控制系统管理元数据非常重要。

### Q: 如何调试问题？

**A:** SchemaQuench 提供详细的日志记录：
- 检查 `Logs/` 目录
- 使用 `Log4Net.config` 调整日志级别
- 运行时添加详细输出标志

### Q: 性能如何？

**A:** SchemaQuench 在设计时考虑了性能：
- 仅应用必要的更改
- 并行处理独立对象
- 优化差异检测算法

### Q: 有生产环境使用案例吗？

**A:** 是的！SchemaSmithyFree 用于生产环境。推荐的工作流程：
1. 在开发环境中开发和测试架构更改
2. 将元数据更改提交到版本控制
3. 在暂存环境中运行 CI/CD 管道
4. 审查和批准更改
5. 部署到生产环境

## 下一步

现在你已经了解了基础知识，可以：

1. 📖 阅读 [工具使用指南](TOOLS_GUIDE.zh-CN.md) 了解每个工具的详细信息
2. 🔍 探索 [TestProducts](../TestProducts/) 中的更多示例
3. 🚀 查看 [SchemaSmithDemos](https://github.com/Schema-Smith/SchemaSmithDemos) 仓库获取更复杂的示例
4. 📚 访问 [Wiki](https://github.com/Schema-Smith/SchemaSmithyFree/wiki) 获取深入文档
5. 🤝 阅读 [贡献指南](../CONTRIBUTING.md) 了解如何参与项目

## 获取帮助

如果遇到问题：
- 🐛 [提交 Issue](https://github.com/Schema-Smith/SchemaSmithyFree/issues)
- 💬 查看现有的 Issues 和 Discussions
- 📖 查阅 Wiki 文档

祝你使用愉快！🎉
