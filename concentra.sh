#!/bin/bash

sudo apt update && sudo apt upgrade -y
sudo apt autoremove -y

# Verificar se Python 3 está instalado
if ! command -v python3 &> /dev/null; then
  echo "Python3 não encontrado. Instalando..."

  if [ -f /etc/debian_version ]; then
    sudo apt update
    sudo apt install -y python3 python3-pip
  elif [ -f /etc/redhat-release ]; then
    sudo yum install -y python3 python3-pip
  else
    echo "Distribuição Linux não suportada automaticamente. Instale o Python 3 manualmente."
    exit 1
  fi
else
  echo "✅ Python3 já está instalado."
fi

# Verificar se pip está instalado
if ! command -v pip3 &> /dev/null; then
  echo "pip3 não encontrado. Instalando..."

  if [ -f /etc/debian_version ]; then
    sudo apt install -y python3-pip
  elif [ -f /etc/redhat-release ]; then
    sudo yum install -y python3-pip
  else
    echo "Distribuição Linux não suportada automaticamente. Instale o pip manualmente."
    exit 1
  fi
else
  echo "✅ pip3 já está instalado."
fi

# Instalar dependências Python
pip3 install --user --upgrade pip
pip3 install --user requests lxml

APP_DIR="/opt/cupons"
CONFIG_FILE="$APP_DIR/config.ini"
PROCESSADOS_FILE="$APP_DIR/cupons.txt"
LOG_FILE="/var/log/cupons.log"
PY_FILE="$APP_DIR/app.py"

# Perguntar ao usuário os dados necessários
read -p "Informe o ID da loja: " ID_LOJA
read -p "Informe o número do ECF: " NUMERO_ECF
read -p "Informe o caminho do diretório dos XMLs: " DIRETORIO_XML

# Criar diretório principal
sudo mkdir -p "$APP_DIR"
sudo chown "$USER:$USER" "$APP_DIR"

# Criar config.ini
cat > "$CONFIG_FILE" << EOF
[geral]
diretorio_xml = $DIRETORIO_XML
arquivo_processados = $PROCESSADOS_FILE
id_loja = $ID_LOJA
numero_ecf = $NUMERO_ECF
EOF

# Criar arquivo de cupons processados
touch "$PROCESSADOS_FILE"

# Criar app.py
cat > "$PY_FILE" << 'EOF'
import os
import datetime
import requests
from lxml import etree
import configparser

CONFIG_PATH = "/opt/cupons/config.ini"
config = configparser.ConfigParser()
config.read(CONFIG_PATH)

DIRETORIO_XML = config['geral']['diretorio_xml']
ARQUIVO_PROCESSADOS = config['geral']['arquivo_processados']
ENDPOINT_ATUALIZA_ECF = "https://cupom.bomdemaissupermercados.com.br/api/atualiza-ecf.php"
ENDPOINT = "https://cupom.bomdemaissupermercados.com.br/api/cadastramento.php"
ID_LOJA = int(config['geral']['id_loja'])
NUMERO_ECF = config['geral']['numero_ecf']

def carregar_processados():
    if not os.path.exists(ARQUIVO_PROCESSADOS):
        return set()
    with open(ARQUIVO_PROCESSADOS, 'r', encoding='utf-8') as f:
        return set(l.strip() for l in f.readlines())

def salvar_processados(novos):
    with open(ARQUIVO_PROCESSADOS, 'a', encoding='utf-8') as f:
        for nome in novos:
            f.write(nome + '\n')

def eh_de_hoje(caminho):
    data_mod = datetime.datetime.fromtimestamp(os.path.getmtime(caminho)).date()
    return data_mod == datetime.date.today()

def extrair_dados_cupom(xml_path):
    tree = etree.parse(xml_path)
    root = tree.getroot()
    ns = {'ns': root.nsmap[None]}
    numerocupom = root.findtext('.//ns:ide/ns:nNF', namespaces=ns)
    cpf = root.findtext('.//ns:dest/ns:CPF', namespaces=ns)
    return numerocupom, cpf

def processar_e_enviar():
    processados = carregar_processados()
    novos_processados = set()
    cupons_enviar = []

    for nome_arquivo in os.listdir(DIRETORIO_XML):
        if not nome_arquivo.endswith('.xml'):
            continue

        caminho_arquivo = os.path.join(DIRETORIO_XML, nome_arquivo)
        if not eh_de_hoje(caminho_arquivo):
            continue
        if nome_arquivo in processados:
            continue

        try:
            numerocupom, cpf = extrair_dados_cupom(caminho_arquivo)
            if numerocupom:
                cupons_enviar.append({
                    "numerocupom": numerocupom,
                    "cpf": cpf if cpf else None,
                    "id_loja": ID_LOJA,
                    "numero_ecf": NUMERO_ECF
                })
                novos_processados.add(nome_arquivo)
                print(f"Processado: {nome_arquivo} -> Cupom: {numerocupom} | CPF: {cpf if cpf else 'Sem CPF'}")
        except Exception as e:
            print(f"Erro ao processar {nome_arquivo}: {e}")

    if cupons_enviar:
        try:
            response = requests.post(ENDPOINT, json=cupons_enviar, timeout=10)
            if response.status_code == 200:
                print(f"Enviado com sucesso {len(cupons_enviar)} cupons.")
                salvar_processados(novos_processados)
                atualizar_data_ecf()
            else:
                print(f"Erro ao enviar: {response.status_code} - {response.text}")
        except Exception as e:
            print(f"Erro na requisição POST: {e}")
    else:
        print("Nenhum novo cupom para enviar.")
        atualizar_data_ecf()

def atualizar_data_ecf():
    payload = {
        "numero_ecf": NUMERO_ECF,
        "id_loja": ID_LOJA
    }
    try:
        response = requests.post(ENDPOINT_ATUALIZA_ECF, json=payload, timeout=5)
        if response.status_code == 200:
            print("Data do ECF atualizada com sucesso.")
        else:
            print(f"Erro ao atualizar data do ECF: {response.status_code} - {response.text}")
    except Exception as e:
        print(f"Erro na requisição de atualização do ECF: {e}")

if __name__ == "__main__":
    print(f"[{datetime.datetime.now()}] Iniciando processamento de cupons...")
    processar_e_enviar()
EOF

chmod +x "$PY_FILE"

# Criar cronjob (executa a cada 5 minutos com python3 do sistema)
PY_PATH=$(which python3)
CRON_JOB="*/5 * * * * $PY_PATH $PY_FILE >> $LOG_FILE 2>&1"
(crontab -l 2>/dev/null | grep -F "$PY_FILE") || (crontab -l 2>/dev/null; echo "$CRON_JOB") | crontab -

# Executar pela primeira vez
$PY_PATH "$PY_FILE"

echo ""
echo "✅ Instalação e configuração finalizadas. O script será executado a cada 5 minutos."

echo ""
echo "📦 Versão do sistema:"
if command -v lsb_release &> /dev/null; then
  lsb_release -a
else
  cat /etc/os-release
fi

