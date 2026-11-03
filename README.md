# TripMatch

毕业旅行拼团规划工具 Demo。发起人可以创建旅行、收集偏好并查看分组；参与人可以匿名提交预算、时间和目的地偏好，查看拼团状态并参与投票。

## 功能

- 发起人和参与人双角色流程
- 创建旅行需求卡
- 中国省份、城市两级选择
- 人均预算范围选择
- 邀请链接与参与偏好填写
- 按预算、时间和目的地自动分组
- 参与人拼团卡片与成员胶囊
- 目的地投票和成团结果
- “我的”活动分类记录
- 跨设备邀请、回传与组队结果发布（Supabase）
- 每人唯一用户 ID、邮箱验证码登录与登录态恢复
- 同一用户在同一活动中只保留一条参与记录
- 响应式移动端布局

## 本地运行

项目不需要安装依赖，可以直接打开 `index.html`，或运行静态服务器：

```bash
python3 -m http.server 4173
```

然后访问 `http://127.0.0.1:4173`。

## 部署到 GitHub Pages

1. 在 GitHub 创建一个空仓库，例如 `tripmatch`。
2. 将本仓库推送到 GitHub 的 `main` 分支。
3. 打开仓库 `Settings > Pages`。
4. 在 `Build and deployment` 中选择 `GitHub Actions`。
5. 等待 `Deploy static site to GitHub Pages` 工作流完成。

网页地址通常为：

```text
https://<你的用户名>.github.io/tripmatch/
```

以后只要向 `main` 分支推送修改，原网页链接就会自动更新。

## 开启跨设备同步

1. 在 Supabase 新建项目。
2. 打开 SQL Editor，执行 `supabase.sql`。
3. 在 `config.js` 填入项目 URL 和 anon public key。
4. 在 `Authentication > Providers` 开启 Email，并使用邮箱验证码模板。
5. 提交并推送到 GitHub，原 Pages 域名会自动更新。

`config.js` 中的 anon key 是 Supabase 设计为可公开使用的浏览器密钥；数据库表已开启 RLS，网页只通过限定的 RPC 方法访问数据。发起人管理令牌和参与人令牌保存在各自设备中，不进入邀请链接。

## 数据说明

配置 Supabase 后，活动、参与偏好和已发布分组会跨设备同步；浏览器 `localStorage` 只保存当前设备的身份令牌和离线缓存。

登录后的数据归属规则：活动通过 `owner_user_id` 绑定发起人，参与记录通过 `user_id` 绑定参与人。刷新或重新打开会恢复登录态并重新读取账号数据；退出登录不会删除数据库记录。

未配置 Supabase 时会自动进入本地演示模式：

- 刷新页面后数据不会丢失。
- 不同浏览器、设备之间的数据不会同步。
- 清理浏览器网站数据会删除本地活动记录。

如需真实跨设备协作，需要接入后端数据库和身份系统。
