"""
app.py — Dashboard de Monitoramento e Previsão
Concessão de Rodovias (projeto de portfólio)

Execução:
    streamlit run app.py
"""
from __future__ import annotations

import os
import sys

import pandas as pd
import plotly.graph_objects as go
import streamlit as st

# -------------------------------------------------------------------------
# Ajuste de path para a estrutura de pastas do projeto:
#
#   Concessionária de Rodovias/
#   ├── dashboard_rodovias/      <- app.py, db.py, monitoring.py (este arquivo)
#   ├── sazonal_e_alertas/       <- forecasting.py
#   └── previsao/                <- requirements.txt, secrets.toml.example
#
# forecasting.py está numa pasta irmã, não na mesma pasta de app.py, então
# precisamos adicioná-la ao sys.path manualmente antes do import.
# -------------------------------------------------------------------------
_BASE_DIR = os.path.dirname(os.path.abspath(__file__))
_PROJETO_DIR = os.path.dirname(_BASE_DIR)
sys.path.insert(0, os.path.join(_PROJETO_DIR, "sazonal_e_alertas"))

import db
import forecasting
import monitoring

st.set_page_config(
    page_title="Monitoramento de Rodovias",
    page_icon="🛣️",
    layout="wide",
)

# -------------------------------------------------------------------------
# Sidebar — conexão e filtros
# -------------------------------------------------------------------------
st.sidebar.title("🛣️ Concessão de Rodovias")
st.sidebar.caption("Monitoramento e previsão sazonal")

ok, msg = db.test_connection()
if not ok:
    st.error(
        "**Não foi possível conectar ao data warehouse.**\n\n"
        f"Detalhe técnico: `{msg}`\n\n"
        "Configure as credenciais em `.streamlit/secrets.toml` "
        "(veja `secrets.toml.example`) ou defina as variáveis de ambiente "
        "`MYSQL_HOST`, `MYSQL_PORT`, `MYSQL_USER`, `MYSQL_PASSWORD`, "
        "`MYSQL_DATABASE` antes de iniciar o Streamlit."
    )
    st.stop()

trechos = db.listar_trechos()
opcoes_trecho = {"Todos os trechos": None}
opcoes_trecho.update(
    {
        f"{row.codigo} — {row.municipio_ini} → {row.municipio_fim}": row.id_trecho
        for row in trechos.itertuples()
    }
)
trecho_label = st.sidebar.selectbox("Trecho", list(opcoes_trecho.keys()))
id_trecho = opcoes_trecho[trecho_label]

horizonte = st.sidebar.slider("Horizonte de previsão (meses)", 3, 12, 6)

st.sidebar.divider()
modelo_status = "Prophet + SARIMA (seleção automática)" if forecasting.PROPHET_DISPONIVEL else "SARIMA (Prophet não instalado)"
st.sidebar.caption(f"Motor de previsão: {modelo_status}")
st.sidebar.caption(
    "Dados sintéticos gerados para fins de portfólio — "
    "não representam uma concessão real."
)


# -------------------------------------------------------------------------
# Funções auxiliares de apresentação
# -------------------------------------------------------------------------
def grafico_previsao(
    historico: pd.DataFrame,
    previsao: pd.DataFrame,
    titulo: str,
    eixo_y: str,
    cor: str = "#1f6f54",
) -> go.Figure:
    fig = go.Figure()

    fig.add_trace(
        go.Scatter(
            x=historico["ds"], y=historico["y"],
            mode="lines", name="Histórico",
            line=dict(color=cor, width=2),
        )
    )
    fig.add_trace(
        go.Scatter(
            x=previsao["ds"], y=previsao["yhat"],
            mode="lines", name="Previsão",
            line=dict(color=cor, width=2, dash="dash"),
        )
    )
    fig.add_trace(
        go.Scatter(
            x=pd.concat([previsao["ds"], previsao["ds"][::-1]]),
            y=pd.concat([previsao["yhat_upper"], previsao["yhat_lower"][::-1]]),
            fill="toself", fillcolor="rgba(31,111,84,0.15)",
            mode="none",
            hoverinfo="skip",
            name="Intervalo de confiança (85%)",
        )
    )
    fig.update_layout(
        title=titulo,
        yaxis_title=eixo_y,
        height=380,
        margin=dict(l=10, r=10, t=50, b=10),
        legend=dict(orientation="h", yanchor="bottom", y=1.02),
        hovermode="x unified",
    )
    return fig


def fmt_br(valor: float, formato: str = "{:,.0f}", sufixo: str = "") -> str:
    """Formata número no padrão brasileiro: ponto como separador de milhar."""
    return formato.format(valor).replace(",", ".") + sufixo


def cartoes_kpi(
    kpis: dict,
    formato: str = "{:,.0f}",
    sufixo: str = "",
    direcao_ruim: str = "alta",
) -> None:
    # Por padrão, st.metric assume "subir = bom (verde), descer = ruim
    # (vermelho)". Isso está certo para receita, mas é o oposto da
    # realidade para acidentes e custo de manutenção, onde subir é a
    # notícia ruim. "inverse" corrige essa semântica nesses casos.
    cor_delta = "inverse" if direcao_ruim == "alta" else "normal"

    c1, c2, c3 = st.columns(3)
    c1.metric(
        "Último mês",
        fmt_br(kpis.get("ultimo_valor", 0), formato, sufixo),
        f"{kpis['var_mom_pct']:.1f}% vs mês anterior".replace(".", ",") if kpis.get("var_mom_pct") is not None else None,
        delta_color=cor_delta,
    )
    c2.metric(
        "Variação anual (YoY)",
        f"{kpis['var_yoy_pct']:.1f}%".replace(".", ",") if kpis.get("var_yoy_pct") is not None else "—",
    )
    c3.metric(
        "Desvio sazonal",
        f"{kpis['desvio_sazonal_pct']:.1f}%".replace(".", ",") if kpis.get("desvio_sazonal_pct") is not None else "—",
        help="Comparação do último valor com a média histórica do mesmo mês-calendário",
    )


def secao_serie(
    titulo_secao: str,
    df: pd.DataFrame,
    coluna: str,
    rotulo_eixo: str,
    formato: str,
    sufixo: str,
    nome_metrica: str,
    direcao_ruim: str,
    cor: str,
    limite_alerta: float = 20.0,
) -> None:
    st.subheader(titulo_secao)

    if df.empty or df[coluna].sum() == 0:
        st.info("Sem dados suficientes para esta seleção.")
        return

    kpis = monitoring.calcular_kpis(df, coluna)
    cartoes_kpi(kpis, formato, sufixo, direcao_ruim)

    for alerta in monitoring.gerar_alertas(kpis, nome_metrica, limite_alerta, direcao_ruim):
        st.warning(f"⚠️ {alerta}")

    with st.spinner(f"Treinando modelos de previsão para {nome_metrica.lower()}..."):
        resultado = forecasting.selecionar_e_prever(df, coluna, periods=horizonte)

    fig = grafico_previsao(
        resultado["historico"], resultado["previsao"],
        f"{titulo_secao} — histórico e previsão", rotulo_eixo, cor,
    )
    st.plotly_chart(fig, use_container_width=True)

    info = f"Modelo selecionado: **{resultado['modelo_escolhido']}**"
    if resultado["mape_prophet"] is not None or resultado["mape_sarima"] is not None:
        info += (
            f" · MAPE no teste — Prophet: {resultado['mape_prophet']}% "
            f"| SARIMA: {resultado['mape_sarima']}%"
        )
    st.caption(info)


# -------------------------------------------------------------------------
# Abas principais
# -------------------------------------------------------------------------
st.title("Monitoramento e Previsão — Concessão de Rodovias")
st.caption(f"Filtro atual: **{trecho_label}**  ·  Horizonte de previsão: **{horizonte} meses**")

aba_trafego, aba_acidentes, aba_arrecadacao, aba_manutencao = st.tabs(
    ["🚗 Tráfego", "🚨 Acidentes", "💰 Arrecadação", "🛠️ Manutenção"]
)

with aba_trafego:
    df = db.trafego_mensal(id_trecho)
    secao_serie(
        "Volume de veículos", df, "volume_total", "Veículos / mês",
        "{:,.0f}", "", "Volume de tráfego", "baixa", "#1f6f54", limite_alerta=25,
    )

with aba_acidentes:
    df = db.acidentes_mensal(id_trecho)
    secao_serie(
        "Ocorrências registradas", df, "total_ocorrencias", "Ocorrências / mês",
        "{:,.0f}", "", "Número de acidentes", "alta", "#b3422d", limite_alerta=25,
    )

with aba_arrecadacao:
    df = db.arrecadacao_mensal(id_trecho)
    secao_serie(
        "Receita de arrecadação", df, "receita_total", "R$ / mês",
        "R$ {:,.0f}", "", "Receita de arrecadação", "baixa", "#1f5c8b", limite_alerta=15,
    )

with aba_manutencao:
    df = db.manutencao_mensal(id_trecho)
    secao_serie(
        "Custo de manutenção", df, "custo_total", "R$ / mês",
        "R$ {:,.0f}", "", "Custo de manutenção", "alta", "#8a6d1f", limite_alerta=30,
    )
