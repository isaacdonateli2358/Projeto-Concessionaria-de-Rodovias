# Dashboard de Monitoramento e Previsão — Concessão de Rodovias

Aplicação Streamlit que conecta ao data warehouse MySQL (`dw_rodovias`),
calcula indicadores de monitoramento e gera previsões sazonais para
tráfego, acidentes, arrecadação e manutenção.

## Estrutura

O projeto está organizado em três pastas temáticas dentro de
`Concessionária de Rodovias/`:

```
Concessionária de Rodovias/
├── dashboard_rodovias/
│   ├── app.py               # Aplicação Streamlit (entrada principal)
│   ├── db.py                # Conexão e queries ao data warehouse
│   └── monitoring.py        # Cálculo de KPIs (MoM, YoY, desvio sazonal) e alertas
├── sazonal_e_alertas/
│   └── forecasting.py       # Seleção automática Prophet x SARIMA + previsão
├── previsao/
│   ├── requirements.txt
│   └── secrets.toml.example # Modelo de configuração de credenciais
├── dw_concessao_rodovias.sql
├── esquema_projeto.jpg
└── README.md
```

`app.py` adiciona `sazonal_e_alertas/` ao `sys.path` automaticamente no
início da execução, então `import forecasting` funciona mesmo o arquivo
estando numa pasta irmã — não é preciso mover nada.

## Como o sistema escolhe o modelo de previsão

Para cada série mensal, `forecasting.py`:

1. Separa os últimos 6 meses como conjunto de teste (holdout).
2. Treina **Prophet** (se a biblioteca estiver instalada) e **SARIMA**
   (`statsmodels`) apenas com os meses restantes.
3. Compara o erro de cada modelo no holdout usando MAPE (erro percentual
   absoluto médio).
4. Re-treina o modelo vencedor com o histórico completo e gera a
   previsão real para os próximos meses (3 a 12, configurável na barra
   lateral).

Se o Prophet não estiver instalado no ambiente, o sistema usa SARIMA
para todas as séries automaticamente — não é necessário alterar código.

## Instalação

```bash
cd "Concessionária de Rodovias"
python3 -m venv venv
source venv/bin/activate          # Windows: venv\Scripts\activate
pip install -r previsao/requirements.txt
```

No PowerShell/CMD do Windows, com a estrutura de pastas em
`C:\Users\nosso\Desktop\Analise de Dados\Power BI\Concessionária de Rodovias`:

```powershell
cd "C:\Users\nosso\Desktop\Analise de Dados\Power BI\Concessionária de Rodovias"
python -m venv venv
venv\Scripts\activate
pip install -r previsao\requirements.txt
```

> Se a instalação do `prophet` falhar (ele depende de um compilador
> C++/cmdstan), remova a linha do `requirements.txt` e reinstale — o
> dashboard funciona normalmente apenas com SARIMA.

## Configuração do banco

Escolha uma das opções:

**Opção A — secrets.toml (recomendado)**

O Streamlit procura `.streamlit/secrets.toml` na pasta a partir de onde
você roda o comando `streamlit run`. Como você vai rodar de dentro de
`dashboard_rodovias/` (veja "Executar" abaixo), o arquivo precisa estar
ali — mesmo o exemplo estando em `previsao/`:

```bash
# a partir da pasta "Concessionária de Rodovias"
mkdir -p dashboard_rodovias/.streamlit
cp previsao/secrets.toml.example dashboard_rodovias/.streamlit/secrets.toml
# edite dashboard_rodovias/.streamlit/secrets.toml com suas credenciais
```

No Windows:
```powershell
mkdir dashboard_rodovias\.streamlit
copy previsao\secrets.toml.example dashboard_rodovias\.streamlit\secrets.toml
notepad dashboard_rodovias\.streamlit\secrets.toml
```

**Opção B — variáveis de ambiente**

Mais simples se você não quiser se preocupar com a pasta `.streamlit`:

```bash
export MYSQL_HOST=localhost
export MYSQL_PORT=3306
export MYSQL_USER=root
export MYSQL_PASSWORD=sua_senha
export MYSQL_DATABASE=dw_rodovias
```

## Pré-requisito: DW populado

Execute, nesta ordem, os dois scripts SQL gerados anteriormente no MySQL:

```bash
mysql -u root -p < dw_concessao_rodovias.sql     # cria schema, dimensões e views
mysql -u root -p < dw_populate_rodovias.sql      # popula com dados sintéticos (2022 a jun/2026)
```

## Executar

```bash
cd dashboard_rodovias
streamlit run app.py
```

O dashboard abre em `http://localhost:8501` com 4 abas (Tráfego,
Acidentes, Arrecadação, Manutenção), cada uma com:

- 3 cartões de KPI (último mês, variação anual, desvio sazonal)
- Alertas automáticos quando o desvio sazonal ultrapassa um limite
- Gráfico de histórico + previsão com intervalo de confiança de 85%
- Indicação de qual modelo foi escolhido e seu erro (MAPE) no teste

Use o filtro de **trecho** na barra lateral para analisar a rodovia
inteira ou um segmento específico.
