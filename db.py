"""
db.py — Camada de acesso ao Data Warehouse (MySQL)
Concessão de Rodovias — Sistema de Monitoramento e Previsão

Lê as credenciais de conexão de st.secrets (recomendado) ou de variáveis
de ambiente, com valores padrão para desenvolvimento local.
"""
from __future__ import annotations

import os
from typing import Optional

import pandas as pd
import streamlit as st
from sqlalchemy import create_engine, text


# -----------------------------------------------------------------------
# Conexão
# -----------------------------------------------------------------------
def _cfg(chave: str, default: str) -> str:
    try:
        if "mysql" in st.secrets and chave in st.secrets["mysql"]:
            return str(st.secrets["mysql"][chave])
    except Exception:
        pass
    return os.getenv(f"MYSQL_{chave.upper()}", default)


@st.cache_resource(show_spinner=False)
def get_engine():
    host = _cfg("host", "localhost")
    port = _cfg("port", "3306")
    user = _cfg("user", "root")
    password = _cfg("password", "")
    database = _cfg("database", "dw_rodovias")
    url = f"mysql+pymysql://{user}:{password}@{host}:{port}/{database}"
    return create_engine(url, pool_pre_ping=True, pool_recycle=3600)


def test_connection() -> tuple[bool, str]:
    try:
        with get_engine().connect() as conn:
            conn.execute(text("SELECT 1"))
        return True, "Conectado ao data warehouse."
    except Exception as e:
        return False, str(e)


# -----------------------------------------------------------------------
# Utilitário: garante calendário mensal contínuo (sem buracos)
# Necessário porque acidentes/manutenção podem não ter nenhum registro
# em um mês específico, o que faria o GROUP BY pular esse mês.
# -----------------------------------------------------------------------
def _completar_calendario_mensal(df: pd.DataFrame) -> pd.DataFrame:
    if df.empty:
        return df
    df = df.copy()
    df["data_ref"] = pd.to_datetime(df["data_ref"])

    # Remove o mês corrente se ele ainda não estiver completo.
    # Um mês é considerado incompleto quando a data de referência
    # (sempre o dia 1 do mês) coincide com o mês atual do sistema —
    # nesse caso, o banco tem menos dias que o mês inteiro, o que
    # distorce totais e a previsão que parte desse ponto.
    hoje = pd.Timestamp.today().normalize()
    mes_atual = hoje.to_period("M").to_timestamp()
    df = df[df["data_ref"] < mes_atual]

    if df.empty:
        return df

    completo = pd.date_range(df["data_ref"].min(), df["data_ref"].max(), freq="MS")
    df = df.set_index("data_ref").reindex(completo)
    df.index.name = "data_ref"
    df = df.fillna(0).reset_index()
    df["ano"] = df["data_ref"].dt.year
    df["mes"] = df["data_ref"].dt.month
    return df


# -----------------------------------------------------------------------
# Dimensões auxiliares
# -----------------------------------------------------------------------
@st.cache_data(ttl=600, show_spinner=False)
def listar_trechos() -> pd.DataFrame:
    sql = """
        SELECT id_trecho, codigo, rodovia, municipio_ini, municipio_fim
        FROM dim_trecho
        ORDER BY km_inicial
    """
    return pd.read_sql(sql, get_engine())


# -----------------------------------------------------------------------
# Séries mensais por tema — uma função por tabela fato
# -----------------------------------------------------------------------
@st.cache_data(ttl=600, show_spinner=False)
def trafego_mensal(id_trecho: Optional[int] = None) -> pd.DataFrame:
    filtro = "AND f.id_trecho = :id_trecho" if id_trecho else ""
    sql = f"""
        SELECT
            t.ano, t.mes,
            STR_TO_DATE(CONCAT(t.ano,'-',t.mes,'-01'), '%Y-%m-%d') AS data_ref,
            SUM(f.volume_veiculos)                                       AS volume_total,
            SUM(CASE WHEN c.tipo = 'Leve' THEN f.volume_veiculos ELSE 0 END)  AS volume_leve,
            SUM(CASE WHEN c.tipo != 'Leve' THEN f.volume_veiculos ELSE 0 END) AS volume_pesado,
            ROUND(AVG(f.velocidade_media), 1)                            AS velocidade_media,
            ROUND(AVG(f.indice_congestion), 3)                           AS congestion_medio
        FROM fact_trafego f
        JOIN dim_tempo t ON f.id_tempo = t.id_tempo
        JOIN dim_categoria_veiculo c ON f.id_categoria = c.id_categoria
        WHERE 1=1 {filtro}
        GROUP BY t.ano, t.mes
        ORDER BY t.ano, t.mes
    """
    params = {"id_trecho": id_trecho} if id_trecho else {}
    df = pd.read_sql(text(sql), get_engine(), params=params)
    return _completar_calendario_mensal(df)


@st.cache_data(ttl=600, show_spinner=False)
def acidentes_mensal(id_trecho: Optional[int] = None) -> pd.DataFrame:
    filtro = "AND f.id_trecho = :id_trecho" if id_trecho else ""
    sql = f"""
        SELECT
            t.ano, t.mes,
            STR_TO_DATE(CONCAT(t.ano,'-',t.mes,'-01'), '%Y-%m-%d') AS data_ref,
            COUNT(*)                                               AS total_ocorrencias,
            SUM(f.qtd_obitos)                                      AS total_obitos,
            SUM(f.qtd_feridos_graves + f.qtd_feridos_leves)        AS total_feridos,
            ROUND(AVG(f.tempo_atendimento_min), 1)                 AS tempo_medio_atend
        FROM fact_acidentes f
        JOIN dim_tempo t ON f.id_tempo = t.id_tempo
        WHERE 1=1 {filtro}
        GROUP BY t.ano, t.mes
        ORDER BY t.ano, t.mes
    """
    params = {"id_trecho": id_trecho} if id_trecho else {}
    df = pd.read_sql(text(sql), get_engine(), params=params)
    return _completar_calendario_mensal(df)


@st.cache_data(ttl=600, show_spinner=False)
def arrecadacao_mensal(id_trecho: Optional[int] = None) -> pd.DataFrame:
    filtro = "AND tr.id_trecho = :id_trecho" if id_trecho else ""
    sql = f"""
        SELECT
            t.ano, t.mes,
            STR_TO_DATE(CONCAT(t.ano,'-',t.mes,'-01'), '%Y-%m-%d') AS data_ref,
            SUM(f.receita_bruta)      AS receita_total,
            SUM(f.qtd_transacoes)     AS total_transacoes,
            SUM(f.evasao_estimada)    AS evasao_total
        FROM fact_arrecadacao f
        JOIN dim_tempo t          ON f.id_tempo = t.id_tempo
        JOIN dim_praca_pedagio p  ON f.id_praca  = p.id_praca
        JOIN dim_trecho tr        ON p.id_trecho = tr.id_trecho
        WHERE 1=1 {filtro}
        GROUP BY t.ano, t.mes
        ORDER BY t.ano, t.mes
    """
    params = {"id_trecho": id_trecho} if id_trecho else {}
    df = pd.read_sql(text(sql), get_engine(), params=params)
    return _completar_calendario_mensal(df)


@st.cache_data(ttl=600, show_spinner=False)
def manutencao_mensal(id_trecho: Optional[int] = None) -> pd.DataFrame:
    filtro = "AND f.id_trecho = :id_trecho" if id_trecho else ""
    sql = f"""
        SELECT
            t.ano, t.mes,
            STR_TO_DATE(CONCAT(t.ano,'-',t.mes,'-01'), '%Y-%m-%d') AS data_ref,
            COUNT(*)                    AS total_ordens,
            SUM(f.custo_total)          AS custo_total,
            SUM(f.extensao_tratada_km)  AS extensao_total_km
        FROM fact_manutencao f
        JOIN dim_tempo t ON f.id_tempo = t.id_tempo
        WHERE 1=1 {filtro}
        GROUP BY t.ano, t.mes
        ORDER BY t.ano, t.mes
    """
    params = {"id_trecho": id_trecho} if id_trecho else {}
    df = pd.read_sql(text(sql), get_engine(), params=params)
    return _completar_calendario_mensal(df)
