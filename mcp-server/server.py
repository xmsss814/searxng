"""SearXNG MCP Server.

通过 MCP (Streamable HTTP) 暴露 SearXNG 的搜索、配置、搜索建议能力。
内部走 docker network 直连 SearXNG 容器,无需 Basic Auth。
外部由 Nginx /mcp 路径统一保护。
"""

from __future__ import annotations

import os
from typing import Any

import httpx
from fastmcp import FastMCP

SEARXNG_BASE_URL = os.environ.get("SEARXNG_INTERNAL_URL", "http://searxng:8080")
HTTP_TIMEOUT = float(os.environ.get("SEARXNG_TIMEOUT", "15"))

mcp = FastMCP("searxng")


async def _get(path: str, params: dict[str, Any] | None = None) -> dict[str, Any]:
    async with httpx.AsyncClient(timeout=HTTP_TIMEOUT) as client:
        resp = await client.get(f"{SEARXNG_BASE_URL}{path}", params=params)
        resp.raise_for_status()
        return resp.json()


@mcp.tool()
async def searxng_search(
    query: str,
    categories: str | None = None,
    language: str | None = None,
    time_range: str | None = None,
    pageno: int = 1,
    safesearch: int | None = None,
    engines: str | None = None,
) -> dict[str, Any]:
    """通过 SearXNG 元搜索引擎执行搜索查询,聚合多个搜索引擎的结果。

    Args:
        query: 搜索关键词 (必填)。
        categories: 在指定分类中搜索,逗号分隔。常用: general, images, news, videos, it, science, files, social media。默认 general。
        language: 结果语言,如 "zh-Hans"、"en"、"all"。留空使用 SearXNG 默认。
        time_range: 限制时间范围。可选: day, week, month, year。留空不限制。
        pageno: 页码,从 1 开始。每页约 10-20 条。
        safesearch: 安全搜索级别 0/1/2 (0=关闭,1=中等,2=严格)。留空使用 SearXNG 默认。
        engines: 强制使用指定引擎,逗号分隔 (如 "google,bing,duckduckgo")。留空自动选择。

    Returns:
        包含 unresponsive_engines、results、number_of_results、suggestions、infoboxes 等字段的 JSON。
        results 中每项通常含 url、title、content、engine、score 字段。
    """
    params: dict[str, Any] = {"q": query, "format": "json", "pageno": pageno}
    if categories:
        params["categories"] = categories
    if language:
        params["language"] = language
    if time_range:
        params["time_range"] = time_range
    if safesearch is not None:
        params["safesearch"] = safesearch
    if engines:
        params["engines"] = engines
    return await _get("/search", params=params)


@mcp.tool()
async def searxng_config() -> dict[str, Any]:
    """获取 SearXNG 实例的配置信息,包括可用的搜索引擎、分类、默认设置。

    调用此工具可以帮助选择 searxng_search 的最佳参数 (如 engines、categories)。
    返回 engines (按分类组织) 和 plugins 列表。
    """
    return await _get("/config")


@mcp.tool()
async def searxng_autocomplete(q: str, language: str | None = None) -> list[Any]:
    """获取搜索关键词的自动补全建议。

    Args:
        q: 已输入的部分查询词,通常 2+ 字符。
        language: 提示语言,如 "zh-Hans"、"en"。留空使用 SearXNG 默认。

    Returns:
        建议词列表 (字符串或 {text,...} 对象,取决于 SearXNG 配置的 autocomplete 引擎)。
    """
    params: dict[str, Any] = {"q": q}
    if language:
        params["language"] = language
    return await _get("/autocompeter", params=params)


if __name__ == "__main__":
    host = os.environ["MCP_HOST"]
    port = int(os.environ["MCP_PORT"])
    mcp.run(transport="streamable-http", host=host, port=port)
