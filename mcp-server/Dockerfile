FROM python:3.12-slim

WORKDIR /app

# 容器网络出口可能存在 SSL 拦截 (自签 CA), 使用国内镜像并标记为 trusted-host
# 避免 pip 校验证书失败
COPY requirements.txt ./
RUN pip install --no-cache-dir \
    -i https://pypi.tuna.tsinghua.edu.cn/simple \
    --trusted-host pypi.tuna.tsinghua.edu.cn \
    -r requirements.txt

COPY server.py ./

ENV MCP_HOST=0.0.0.0
ENV MCP_PORT=8000
ENV PYTHONUNBUFFERED=1

EXPOSE 8000

CMD ["python", "server.py"]
