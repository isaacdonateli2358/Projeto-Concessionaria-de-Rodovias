"""
monitoring.py — Cálculo de indicadores de monitoramento e alertas
Concessão de Rodovias — Sistema de Monitoramento e Previsão
"""
from __future__ import annotations

from typing import List

import pandas as pd


def calcular_kpis(df: pd.DataFrame, coluna: str, janela_media: int = 3) -> dict:
    """
    Calcula KPIs de monitoramento para uma série mensal:
      - ultimo_valor       : valor do último mês disponível
      - var_mom_pct        : variação % vs mês anterior (Month over Month)
      - var_yoy_pct        : variação % vs mesmo mês do ano anterior (Year over Year)
      - media_movel        : média móvel dos últimos `janela_media` meses
      - desvio_sazonal_pct : desvio do último valor vs média histórica do
                              mesmo mês-calendário (ex: compara set/24 com a
                              média de todos os setembros anteriores)
    """
    if df.empty or len(df) < 2:
        return {}

    serie = df[coluna].astype(float).reset_index(drop=True)

    ultimo = serie.iloc[-1]
    anterior = serie.iloc[-2]
    var_mom = (ultimo / anterior - 1) * 100 if anterior else None

    var_yoy = None
    if len(serie) >= 13:
        mesmo_mes_ano_passado = serie.iloc[-13]
        if mesmo_mes_ano_passado:
            var_yoy = (ultimo / mesmo_mes_ano_passado - 1) * 100

    media_movel = serie.tail(janela_media).mean()

    desvio_sazonal = None
    if "mes" in df.columns and len(df) >= 13:
        mes_atual = df["mes"].iloc[-1]
        historico_mesmo_mes = df[df["mes"] == mes_atual][coluna].iloc[:-1]
        if len(historico_mesmo_mes) > 0:
            media_sazonal = historico_mesmo_mes.mean()
            if media_sazonal:
                desvio_sazonal = (ultimo / media_sazonal - 1) * 100

    return {
        "ultimo_valor": ultimo,
        "var_mom_pct": var_mom,
        "var_yoy_pct": var_yoy,
        "media_movel": media_movel,
        "desvio_sazonal_pct": desvio_sazonal,
    }


def gerar_alertas(
    kpis: dict,
    nome_metrica: str,
    limite_pct: float = 20.0,
    direcao_ruim: str = "alta",
) -> List[str]:
    """
    Gera mensagens de alerta quando o desvio sazonal ultrapassa o limite.

    direcao_ruim:
        'alta'  -> alerta quando o valor sobe acima do limite (ex: acidentes, custo)
        'baixa' -> alerta quando o valor cai abaixo do limite (ex: receita, velocidade)
    """
    alertas: List[str] = []
    desvio = kpis.get("desvio_sazonal_pct")
    if desvio is None:
        return alertas

    if direcao_ruim == "alta" and desvio > limite_pct:
        alertas.append(
            f"{nome_metrica} está {desvio:.1f}% acima da média histórica "
            f"para este mês."
        )
    elif direcao_ruim == "baixa" and desvio < -limite_pct:
        alertas.append(
            f"{nome_metrica} está {abs(desvio):.1f}% abaixo da média "
            f"histórica para este mês."
        )
    return alertas
