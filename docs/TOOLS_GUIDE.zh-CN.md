# 工具使用指南

[English](TOOLS_GUIDE.md) | 简体中文

本指南详细介绍 SchemaSmithyFree 工具集中的三个主要工具：SchemaQuench、SchemaTongs 和 DataTongs。

## 目录

- [SchemaQuench - 数据库迁移工具](#schemaquench---数据库迁移工具)
- [SchemaTongs - 模板生成工具](#schematongs---模板生成工具)
- [DataTongs - 数据迁移工具](#datatongs---数据迁移工具)
- [产品结构详解](#产品结构详解)
- [配置文件说明](#配置文件说明)
- [高级使用技巧](#高级使用技巧)

---

## SchemaQuench - 数据库迁移工具

### 概述

SchemaQuench 是核心迁移工具，它读取产品元数据并将 SQL Server 转换为匹配定义的状态。

### 主要功能

- ✅ **状态驱动**: 根据期望的最终状态自动计算并应用更改
- ✅ **智能差异检测**: 仅应用必要的更改，避免不必要的操作
- ✅ **依赖关系管理**: 自动处理对象之间的依赖关系
- ✅ **迁移脚本**: 支持自定义 Before/After 迁移脚本
- ✅ **数据安全**: 在进行破坏性更改前提供警告
- ✅ **回滚支持**: 通过版本控制实现架构回滚

### 使用方法

#### 基本用法

```bash
# 使用 .NET CLI
dotnet run --project SchemaQuench/SchemaQuench.csproj

# 使用编译后的可执行文件
./SchemaQuench.exe
```

#### 配置

SchemaQuench 通过以下方式配置：

1. **appsettings.json** - 应用程序设置
   ```json
   {
     "ConnectionString": "Server=localhost;Database=master;Integrated Security=true;",
     "ProductPath": "./TestProducts/ValidProduct",
     "LogLevel": "Info"
   }
   ```

2. **用户机密** - 敏感信息（推荐）
   ```bash
   dotnet user-secrets set "ConnectionString" "Server=prod;User=admin;Password=***"
   ```

3. **环境变量** - 生产环境配置
   ```bash
   export SchemaQuench__ConnectionString="Server=prod;..."
   export SchemaQuench__ProductPath="/path/to/product"
   ```

#### 命令行参数

```bash
# 跳过 KindlingForge（用于特殊场景）
SchemaQuench.exe SkipKindlingForge

# 显示版本信息
SchemaQuench.exe --version

# 显示帮助信息
SchemaQuench.exe --help
```

### 工作流程

1. **加载产品**: 读取 Product.json 和所有模板定义
2. **连接数据库**: 建立与目标 SQL Server 的连接
3. **分析差异**: 比较当前状态与期望状态
4. **执行迁移脚本 (Before)**: 运行自定义的前置迁移脚本
5. **应用更改**: 创建、修改或删除数据库对象
6. **执行迁移脚本 (After)**: 运行自定义的后置迁移脚本
7. **验证**: 确认所有更改已成功应用
8. **记录日志**: 生成详细的操作日志

### 支持的数据库对象

SchemaQuench 可以管理以下 SQL Server 对象：

- 📊 **表 (Tables)**: 列、约束、索引、触发器
- 👁️ **视图 (Views)**: 标准视图和索引视图
- ⚙️ **存储过程 (Stored Procedures)**: 参数化存储过程
- 🔧 **函数 (Functions)**: 标量函数、表值函数
- 📐 **架构 (Schemas)**: 数据库架构
- 🔤 **数据类型 (User-Defined Types)**: 自定义数据类型
- 🔍 **全文索引 (Full-Text Catalogs/StopLists)**: 全文搜索支持
- ⚡ **触发器 (Triggers)**: 表和数据库触发器

### 最佳实践

1. **版本控制**: 始终将产品元数据置于版本控制（Git）中
2. **测试优先**: 在测试环境中验证更改后再应用到生产环境
3. **备份**: 在运行 SchemaQuench 前备份生产数据库
4. **渐进式更改**: 进行小的、增量式的更改，而不是大的批量更改
5. **审查日志**: 每次运行后检查日志文件，确保按预期执行
6. **CI/CD 集成**: 将 SchemaQuench 集成到 CI/CD 管道中

### 示例场景

#### 场景 1: 添加新表

1. 在 `Templates/Main/Tables/` 创建 `dbo.NewTable.json`:
   ```json
   {
     "TableName": "NewTable",
     "SchemaName": "dbo",
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

2. 运行 SchemaQuench
3. 表会自动创建

#### 场景 2: 修改现有列

1. 编辑表的 JSON 文件，修改列定义
2. 运行 SchemaQuench
3. SchemaQuench 会检测更改并生成 ALTER 语句

#### 场景 3: 使用自定义迁移脚本

如果需要复杂的数据转换：

1. 创建 `MigrationScripts/Before/001_DataTransform.sql`:
   ```sql
   -- 在架构更改前执行的数据转换
   UPDATE OldTable SET Status = 'Active' WHERE Status IS NULL;
   ```

2. 创建 `MigrationScripts/After/001_DataCleanup.sql`:
   ```sql
   -- 在架构更改后执行的清理
   DELETE FROM TempTable WHERE ProcessedDate < DATEADD(day, -30, GETDATE());
   ```

---

## SchemaTongs - 模板生成工具

### 概述

SchemaTongs 从现有的 SQL Server 数据库生成产品元数据。这对于将现有数据库迁移到 SchemaSmithyFree 管理非常有用。

### 主要功能

- 🔄 **逆向工程**: 从现有数据库生成完整的元数据
- 📝 **JSON 表定义**: 自动生成表的 JSON 定义
- 📄 **SQL 对象提取**: 提取存储过程、视图、函数等的 SQL 脚本
- 🏗️ **结构生成**: 创建完整的产品目录结构
- 🎯 **选择性提取**: 可以选择要提取的对象类型

### 使用方法

#### 基本用法

```bash
# 使用 .NET CLI
dotnet run --project SchemaTongs/SchemaTongs.csproj

# 使用编译后的可执行文件
./SchemaTongs.exe
```

#### 配置

在 `appsettings.json` 中配置：

```json
{
  "ConnectionString": "Server=localhost;Database=MyExistingDB;Integrated Security=true;",
  "OutputPath": "./GeneratedProduct",
  "TemplateName": "MyTemplate",
  "IncludeData": false
}
```

### 工作流程

1. **连接源数据库**: 连接到现有 SQL Server 数据库
2. **发现对象**: 枚举所有数据库对象
3. **提取定义**: 获取每个对象的定义
4. **生成元数据**: 创建 JSON 和 SQL 文件
5. **组织结构**: 按照产品结构组织文件
6. **生成配置**: 创建 Product.json 和 Template.json

### 生成的结构

SchemaTongs 生成以下结构：

```
GeneratedProduct/
├── Product.json
└── Templates/
    └── MyTemplate/
        ├── Template.json
        ├── Tables/
        │   ├── dbo.Table1.json
        │   └── dbo.Table2.json
        ├── Procedures/
        │   ├── dbo.Proc1.sql
        │   └── dbo.Proc2.sql
        ├── Views/
        │   └── dbo.View1.sql
        ├── Functions/
        │   └── dbo.Function1.sql
        ├── Schemas/
        │   └── CustomSchema.sql
        └── DataTypes/
            └── CustomType.sql
```

### 最佳实践

1. **清理和审查**: 生成后审查元数据，删除不需要的对象
2. **版本标记**: 设置适当的版本号
3. **数据排除**: 通常不包含实际数据，仅包含架构
4. **测试生成的产品**: 在测试环境中使用 SchemaQuench 验证生成的元数据
5. **手动调整**: 根据需要调整生成的定义

### 示例场景

#### 场景 1: 从现有数据库开始

你有一个现有的生产数据库，想开始使用 SchemaSmithyFree：

1. 配置 SchemaTongs 连接到生产数据库
2. 运行 SchemaTongs 生成元数据
3. 将生成的产品提交到版本控制
4. 从此刻起，使用 SchemaQuench 管理架构更改

#### 场景 2: 创建数据库副本

创建现有数据库的副本用于开发：

1. 使用 SchemaTongs 从生产数据库生成元数据
2. 使用 SchemaQuench 在开发环境中创建数据库
3. 可选：使用 DataTongs 复制一些测试数据

---

## DataTongs - 数据迁移工具

### 概述

DataTongs 处理数据迁移，补充 SchemaQuench 的架构管理功能。它可以将数据从一个数据库移动到另一个数据库。

### 主要功能

- 📦 **数据导出**: 将表数据导出为 XML 格式
- 📥 **数据导入**: 从 XML 文件导入数据
- 🔄 **批量操作**: 高效处理大量数据
- 🎯 **选择性迁移**: 选择要迁移的特定表
- 🔒 **参照完整性**: 尊重外键关系

### 使用方法

#### 基本用法

```bash
# 使用 .NET CLI
dotnet run --project DataTongs/DataTongs.csproj

# 使用编译后的可执行文件
./DataTongs.exe
```

#### 配置

在 `appsettings.json` 中配置：

```json
{
  "ConnectionString": "Server=localhost;Database=SourceDB;Integrated Security=true;",
  "DataPath": "./DataPayloads",
  "Mode": "Export"
}
```

### 数据文件格式

DataTongs 使用 XML 格式存储数据：

```xml
<?xml version="1.0" encoding="utf-8"?>
<DataPayload>
  <Table Name="dbo.Customers">
    <Row>
      <Column Name="Id">1</Column>
      <Column Name="Name">John Doe</Column>
      <Column Name="Email">john@example.com</Column>
    </Row>
    <Row>
      <Column Name="Id">2</Column>
      <Column Name="Name">Jane Smith</Column>
      <Column Name="Email">jane@example.com</Column>
    </Row>
  </Table>
</DataPayload>
```

### 最佳实践

1. **小批量**: 对大表进行分批迁移
2. **测试数据**: 为开发环境创建脱敏的测试数据集
3. **备份**: 在导入数据前备份目标数据库
4. **验证**: 导入后验证数据完整性
5. **性能**: 对于大量数据考虑使用 SQL Server 的 BCP 或 SSIS

### 示例场景

#### 场景 1: 导出测试数据

从生产数据库导出部分数据用于测试：

1. 配置 DataTongs 连接到生产数据库
2. 设置 Mode 为 "Export"
3. 运行 DataTongs
4. 在开发环境中使用导出的数据

#### 场景 2: 种子数据

为新数据库提供初始数据：

1. 创建包含种子数据的 XML 文件
2. 将它们放在产品的 DataPayloads 目录中
3. 使用 DataTongs 导入数据

---

## 产品结构详解

### 标准产品结构

```
MyProduct/
├── Product.json              # 产品配置文件
└── Templates/
    ├── DatabaseA/            # 第一个数据库模板
    │   ├── Template.json     # 模板配置
    │   ├── Tables/           # 表定义 (JSON)
    │   │   ├── dbo.Table1.json
    │   │   └── dbo.Table2.json
    │   ├── Procedures/       # 存储过程 (SQL)
    │   │   └── dbo.Proc1.sql
    │   ├── Views/            # 视图 (SQL)
    │   │   └── dbo.View1.sql
    │   ├── Functions/        # 函数 (SQL)
    │   │   └── dbo.Func1.sql
    │   ├── Triggers/         # 触发器 (SQL)
    │   │   └── dbo.Trigger1.sql
    │   ├── Schemas/          # 架构 (SQL)
    │   │   └── CustomSchema.sql
    │   ├── DataTypes/        # 用户定义类型 (SQL)
    │   │   └── CustomType.sql
    │   ├── FullTextCatalogs/ # 全文目录 (SQL)
    │   ├── FullTextStopLists/ # 全文停用词列表 (SQL)
    │   ├── MigrationScripts/ # 迁移脚本
    │   │   ├── Before/       # 在架构更改前运行
    │   │   └── After/        # 在架构更改后运行
    │   └── DataPayloads/     # 数据文件 (XML)
    └── DatabaseB/            # 第二个数据库模板（可选）
        └── ...
```

### Product.json 详解

```json
{
  "Product": "MyProduct",
  "Version": "1.0.0",
  "Description": "产品描述（可选）",
  "Templates": [
    {
      "TemplateName": "DatabaseA",
      "TemplateVersion": "1.0.0",
      "Description": "主数据库"
    },
    {
      "TemplateName": "DatabaseB",
      "TemplateVersion": "1.0.0",
      "Description": "辅助数据库"
    }
  ]
}
```

### Template.json 详解

```json
{
  "TemplateName": "DatabaseA",
  "DatabaseName": "MyDatabase",
  "Version": "1.0.0",
  "CompatibilityLevel": 150,
  "Collation": "SQL_Latin1_General_CP1_CI_AS",
  "Recovery": "FULL",
  "Description": "模板描述（可选）"
}
```

### 表定义 JSON 详解

```json
{
  "TableName": "Customers",
  "SchemaName": "dbo",
  "Columns": [
    {
      "ColumnName": "Id",
      "DataType": "int",
      "IsNullable": false,
      "IsPrimaryKey": true,
      "IsIdentity": true,
      "IdentitySeed": 1,
      "IdentityIncrement": 1
    },
    {
      "ColumnName": "Name",
      "DataType": "nvarchar(100)",
      "IsNullable": false,
      "DefaultValue": "'Unknown'"
    },
    {
      "ColumnName": "Email",
      "DataType": "nvarchar(255)",
      "IsNullable": true,
      "IsUnique": true
    },
    {
      "ColumnName": "CreatedDate",
      "DataType": "datetime2",
      "IsNullable": false,
      "DefaultValue": "GETDATE()"
    }
  ],
  "Indexes": [
    {
      "IndexName": "IX_Customers_Email",
      "Columns": ["Email"],
      "IsUnique": true,
      "IsClustered": false
    }
  ],
  "ForeignKeys": [
    {
      "ForeignKeyName": "FK_Orders_Customers",
      "Columns": ["CustomerId"],
      "ReferencedTable": "dbo.Customers",
      "ReferencedColumns": ["Id"],
      "OnDelete": "CASCADE"
    }
  ]
}
```

---

## 配置文件说明

### appsettings.json

每个工具都有自己的 `appsettings.json` 文件：

#### SchemaQuench 配置

```json
{
  "ConnectionString": "Server=localhost;Database=master;Integrated Security=true;TrustServerCertificate=true;",
  "ProductPath": "./Products/MyProduct",
  "LogLevel": "Info",
  "DryRun": false,
  "BackupBeforeApply": true
}
```

#### SchemaTongs 配置

```json
{
  "ConnectionString": "Server=localhost;Database=SourceDB;Integrated Security=true;",
  "OutputPath": "./GeneratedProducts/MyProduct",
  "TemplateName": "MyTemplate",
  "IncludeObjects": {
    "Tables": true,
    "Views": true,
    "Procedures": true,
    "Functions": true,
    "Triggers": true,
    "Schemas": true,
    "DataTypes": true
  }
}
```

#### DataTongs 配置

```json
{
  "ConnectionString": "Server=localhost;Database=TargetDB;Integrated Security=true;",
  "DataPath": "./Products/MyProduct/Templates/Main/DataPayloads",
  "Mode": "Import",
  "BatchSize": 1000
}
```

### Log4Net.config

所有工具都使用 Log4Net 进行日志记录：

```xml
<?xml version="1.0" encoding="utf-8" ?>
<log4net>
  <appender name="RollingFileAppender" type="log4net.Appender.RollingFileAppender">
    <file value="Logs/SchemaQuench.log" />
    <appendToFile value="true" />
    <rollingStyle value="Date" />
    <datePattern value="yyyyMMdd" />
    <layout type="log4net.Layout.PatternLayout">
      <conversionPattern value="%date [%thread] %-5level %logger - %message%newline" />
    </layout>
  </appender>
  <root>
    <level value="INFO" />
    <appender-ref ref="RollingFileAppender" />
  </root>
</log4net>
```

---

## 高级使用技巧

### 1. CI/CD 集成

在 CI/CD 管道中使用 SchemaQuench：

```yaml
# GitHub Actions 示例
name: Deploy Database Changes

on:
  push:
    branches: [main]
    paths:
      - 'Products/**'

jobs:
  deploy:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v2
      
      - name: Setup .NET
        uses: actions/setup-dotnet@v1
        with:
          dotnet-version: '9.0.x'
      
      - name: Run SchemaQuench
        env:
          CONNECTION_STRING: ${{ secrets.DB_CONNECTION_STRING }}
        run: |
          dotnet run --project SchemaQuench/SchemaQuench.csproj
```

### 2. 多环境管理

为不同环境使用不同的配置：

```bash
# 开发环境
dotnet run --project SchemaQuench -- --environment Development

# 生产环境
dotnet run --project SchemaQuench -- --environment Production
```

### 3. 并行部署

使用脚本并行部署多个数据库：

```bash
#!/bin/bash
# 并行运行多个 SchemaQuench 实例
for product in ProductA ProductB ProductC; do
  dotnet run --project SchemaQuench -- --product $product &
done
wait
```

### 4. 版本控制最佳实践

```
.gitignore 示例：
Logs/
*.log
appsettings.Development.json
appsettings.*.json
!appsettings.json
bin/
obj/
```

### 5. 自动化测试

在部署前验证元数据：

```csharp
[Test]
public void Product_ShouldHaveValidStructure()
{
    var product = LoadProduct("./Products/MyProduct");
    Assert.IsNotNull(product);
    Assert.IsTrue(product.Templates.Count > 0);
    // 更多验证...
}
```

### 6. 监控和告警

监控 SchemaQuench 执行：

- 检查退出代码
- 解析日志文件
- 设置失败告警
- 跟踪部署历史

---

## 故障排除

### 常见问题

#### 连接失败

```
错误: 无法连接到 SQL Server
解决方案:
- 检查连接字符串
- 验证 SQL Server 正在运行
- 检查防火墙设置
- 确认用户权限
```

#### 对象依赖错误

```
错误: 无法删除对象，因为其他对象依赖它
解决方案:
- 让 SchemaQuench 自动处理依赖关系
- 检查是否有外部依赖
- 使用 Before 迁移脚本手动处理
```

#### 权限不足

```
错误: 用户没有足够的权限
解决方案:
- 确保用户具有 db_owner 角色
- 或授予 ALTER、CREATE、DROP 权限
```

### 获取帮助

- 📖 查看 [Wiki](https://github.com/Schema-Smith/SchemaSmithyFree/wiki)
- 🐛 [提交 Issue](https://github.com/Schema-Smith/SchemaSmithyFree/issues)
- 💬 参与社区讨论

---

## 总结

SchemaSmithyFree 工具集提供了完整的 SQL Server 架构管理解决方案：

- **SchemaQuench**: 将数据库转换为期望状态
- **SchemaTongs**: 从现有数据库生成元数据
- **DataTongs**: 处理数据迁移

结合使用这些工具，可以实现高效、可靠的数据库架构管理工作流程。

## 下一步

- 📖 返回 [新手入门指南](GETTING_STARTED.zh-CN.md)
- 🚀 探索 [SchemaSmithDemos](https://github.com/Schema-Smith/SchemaSmithDemos)
- 🤝 阅读 [贡献指南](../CONTRIBUTING.md)

祝你使用愉快！🎉
