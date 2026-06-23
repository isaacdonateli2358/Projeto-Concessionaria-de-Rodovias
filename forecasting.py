"""
forecasting.py — Seleção automática de modelo e geração de previsões
Concessão de Rodovias — Sistema de Monitoramento e Previsão

Para cada série mensal, treina Prophet (quando disponível) e SARIMA,
avalia ambos num holdout dos últimos meses via MAPE, e usa o modelo
vencedor — retreinado com o histórico completo — para prever os
próximos `periods` meses.

Prophet é importado de forma opcional: se a biblioteca não estiver
instalada, o sistema usa SARIMA para todas as séries automaticamente.
"""
from __future__ import annotations

import warnings
from typing import Optional

import numpy as np
import pandas as pd

warnings.filterwarnings("ignore")

try:
    from prophet import Prophet
    PROPHET_DISPONIVEL = True
except ImportError:
    PROPHET_DISPONIVEL = False

from statsmodels.tsa.statespace.sarimax import SARIMAX


# -----------------------------------------------------------------------
# Utilitários
# -----------------------------------------------------------------------
def _mape(y_true: np.ndarray, y_pred: np.ndarray) -> float:
    y_true, y_pred = np.array(y_true, dtype=float), np.array(y_pred, dtype=float)
    mask = y_true != 0
    if mask.sum() == 0:
        return np.inf
    return float(np.mean(np.abs((y_true[mask] - y_pred[mask]) / y_true[mask])) * 100)


def _preparar_serie(df: pd.DataFrame, coluna: str) -> pd.DataFrame:
    s = df[["data_ref", coluna]].rename(columns={"data_ref": "ds", coluna: "y"}).copy()
    s["ds"] = pd.to_datetime(s["ds"])
    s = s.sort_values("ds").reset_index(drop=True)
    return s


# -----------------------------------------------------------------------
# Treino — Prophet
# -----------------------------------------------------------------------
def _treinar_prophet(treino: pd.DataFrame, periods: int) -> pd.DataFrame:
    m = Prophet(
        yearly_seasonality=True,
        weekly_seasonality=False,
        daily_seasonality=False,
        seasonality_mode="multiplicative",
        interval_width=0.85,
    )
    m.fit(treino)
    futuro = m.make_future_dataframe(periods=periods, freq="MS")
    fcst = m.predict(futuro)
    return fcst[["ds", "yhat", "yhat_lower", "yhat_upper"]]


# -----------------------------------------------------------------------
# Treino — SARIMA
# -----------------------------------------------------------------------
def _treinar_sarima(treino_df: pd.DataFrame, periods: int) -> pd.DataFrame:
    idx = pd.date_range(start=treino_df["ds"].iloc[0], periods=len(treino_df), freq="MS")
    serie = pd.Series(treino_df["y"].values, index=idx)

    ordem_sazonal = (1, 1, 1, 12) if len(serie) >= 24 else (0, 0, 0, 0)
    modelo = SARIMAX(
        serie,
        order=(1, 1, 1),
        seasonal_order=ordem_sazonal,
        enforce_stationarity=False,
        enforce_invertibility=False,
    )
    res = modelo.fit(disp=False)
    pred = res.get_forecast(steps=periods)

    idx_futuro = pd.date_range(idx[-1] + pd.DateOffset(months=1), periods=periods, freq="MS")
    media = pred.predicted_mean.values
    ic = pred.conf_int(alpha=0.15)

    return pd.DataFrame({
        "ds": idx_futuro,
        "yhat": media,
        "yhat_lower": ic.iloc[:, 0].values,
        "yhat_upper": ic.iloc[:, 1].values,
    })


# -----------------------------------------------------------------------
# Proteção contra instabilidade numérica
# -----------------------------------------------------------------------
def _sanitizar_previsao(serie_referencia: pd.DataFrame, previsao: pd.DataFrame) -> pd.DataFrame:
    """
    Às vezes o SARIMA (e, mais raramente, o Prophet) converge mal — em
    geral com séries mais longas e parâmetros sazonais quase não
    estacionários — e produz intervalos de confiança astronômicos
    (ordem de 10^15 ou mais), o que quebra a escala do gráfico mesmo
    quando a previsão central (yhat) é razoável.

    Limitamos yhat/yhat_lower/yhat_upper a uma faixa estatisticamente
    plausível com base no próprio histórico: média ± 6 desvios-padrão,
    com piso em zero (todas as métricas deste projeto — volume, receita,
    custo, contagem de ocorrências — são não-negativas por natureza).
    """
    hist = serie_referencia["y"]
    media, desvio = float(hist.mean()), float(hist.std())

    if desvio == 0 or pd.isna(desvio):
        minimo, maximo = 0.0, max(float(hist.max()) * 3, 1.0)
    else:
        minimo = max(0.0, media - 6 * desvio)
        maximo = media + 6 * desvio

    previsao = previsao.copy()
    for col in ("yhat", "yhat_lower", "yhat_upper"):
        previsao[col] = previsao[col].clip(lower=minimo, upper=maximo)

    # garante consistência lower <= yhat <= upper após o clip
    previsao["yhat_lower"] = previsao[["yhat_lower", "yhat"]].min(axis=1)
    previsao["yhat_upper"] = previsao[["yhat_upper", "yhat"]].max(axis=1)
    return previsao


# -----------------------------------------------------------------------
# Função principal — seleção automática + previsão
# -----------------------------------------------------------------------
def selecionar_e_prever(
    df: pd.DataFrame,
    coluna: str,
    periods: int = 6,
    holdout: int = 6,
) -> dict:
    """
    Retorna um dict com:
        modelo_escolhido : "Prophet" | "SARIMA" | "SARIMA (histórico curto)"
        mape_prophet      : erro percentual do Prophet no holdout (ou None)
        mape_sarima       : erro percentual do SARIMA no holdout (ou None)
        historico         : DataFrame [ds, y] usado no treino
        previsao          : DataFrame [ds, yhat, yhat_lower, yhat_upper]
    """
    serie = _preparar_serie(df, coluna)

    # histórico curto demais para holdout confiável: treina direto com SARIMA simples
    if len(serie) < holdout + 12:
        previsao = _sanitizar_previsao(serie, _treinar_sarima(serie, periods))
        return {
            "modelo_escolhido": "SARIMA (histórico curto)",
            "mape_prophet": None,
            "mape_sarima": None,
            "historico": serie,
            "previsao": previsao,
        }

    treino_df = serie.iloc[:-holdout].reset_index(drop=True)
    teste_df = serie.iloc[-holdout:].reset_index(drop=True)

    mape_prophet: float = np.inf
    mape_sarima: float = np.inf

    if PROPHET_DISPONIVEL:
        try:
            fcst_p = _sanitizar_previsao(treino_df, _treinar_prophet(treino_df, holdout))
            pred_p = fcst_p.tail(holdout)["yhat"].values
            mape_prophet = _mape(teste_df["y"].values, pred_p)
        except Exception:
            mape_prophet = np.inf

    try:
        fcst_s = _sanitizar_previsao(treino_df, _treinar_sarima(treino_df, holdout))
        mape_sarima = _mape(teste_df["y"].values, fcst_s["yhat"].values)
    except Exception:
        mape_sarima = np.inf

    usa_prophet = PROPHET_DISPONIVEL and mape_prophet <= mape_sarima

    # retreina com o histórico COMPLETO para gerar a previsão real
    if usa_prophet:
        bruta = _treinar_prophet(serie, periods).tail(periods).reset_index(drop=True)
        modelo_escolhido = "Prophet"
    else:
        bruta = _treinar_sarima(serie, periods)
        modelo_escolhido = "SARIMA"

    previsao_final = _sanitizar_previsao(serie, bruta)

    return {
        "modelo_escolhido": modelo_escolhido,
        "mape_prophet": None if mape_prophet == np.inf else round(mape_prophet, 2),
        "mape_sarima": None if mape_sarima == np.inf else round(mape_sarima, 2),
        "historico": serie,
        "previsao": previsao_final,
    }
