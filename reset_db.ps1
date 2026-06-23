# reset_db.ps1
# Recria o banco dw_rodovias do zero, com o periodo estendido (2022-01-01 a 2026-06-21).
# Rode este arquivo de dentro da pasta raiz "Concessionaria de Rodovias".

$env:Path += ";C:\Program Files\MySQL\MySQL Server 8.0\bin"

Write-Host "1/3 - Apagando banco antigo (se existir)..." -ForegroundColor Cyan
mysql -u root -p -e "DROP DATABASE IF EXISTS dw_rodovias;"

Write-Host "2/3 - Recriando schema (tabelas, dimensoes, views)..." -ForegroundColor Cyan
Get-Content dw_concessao_rodovias.sql | mysql -u root -p

Write-Host "3/3 - Populando com dados sinteticos (pode demorar um pouco)..." -ForegroundColor Cyan
Get-Content dw_populate_rodovias.sql | mysql -u root -p

Write-Host "Concluido! Banco dw_rodovias recriado com dados de 2022-01-01 a 2026-06-21." -ForegroundColor Green
