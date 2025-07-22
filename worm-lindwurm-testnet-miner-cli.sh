#!/bin/bash
set -e
set -o pipefail

# Цвета
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BOLD='\033[1m'
NC='\033[0m'

# Пути
log_dir="$HOME/.worm-miner"
miner_dir="$HOME/miner"
log_file="$log_dir/miner.log"
key_file1="$log_dir/private.key1"
key_file2="$log_dir/private.key2"
worm_miner_bin="$HOME/.cargo/bin/worm-miner"
fastest_rpc_file="$log_dir/fastest_rpc.log"

# Более надежный список RPC для тестирования
sepolia_rpcs=(
    "https://sepolia.drpc.org"
    "https://ethereum-sepolia-rpc.publicnode.com"
    "https://eth-sepolia.public.blastapi.io"
    "https://eth-sepolia-public.unifra.io"
)

# Помощник: Получить приватный ключ из файла пользователя
get_private_key() {
  local key_file=$1
  if [ ! -f "$key_file" ]; then
    echo -e "${YELLOW}Майнер не установлен или файл ключа отсутствует. Сначала запустите опцию 1.${NC}"
    return 1
  fi
  private_key=$(cat "$key_file")
  if [[ ! $private_key =~ ^0x[0-9a-fA-F]{64}$ ]]; then
    echo -e "${RED}Ошибка: Неверный формат приватного ключа в $key_file${NC}"
    return 1
  fi
  echo "$private_key"
}

# Найти самый быстрый RPC
find_fastest_rpc() {
    echo -e "${GREEN}[*] Поиск самого быстрого Sepolia RPC...${NC}"
    fastest_rpc=""
    min_latency=999999

    for rpc in "${sepolia_rpcs[@]}"; do
        latency=$(curl -o /dev/null --connect-timeout 5 --max-time 10 -s -w "%{time_total}" "$rpc" || echo "999999")
        echo -e "Тестирование RPC: $rpc | Задержка: ${YELLOW}$latency${NC} секунд"
        if (( $(echo "$latency < $min_latency" | bc -l) && $(echo "$latency > 0" | bc -l) )); then
            min_latency=$latency
            fastest_rpc=$rpc
        fi
    done

    if [ -n "$fastest_rpc" ]; then
        echo "$fastest_rpc" > "$fastest_rpc_file"
        echo -e "${GREEN}[+] Самый быстрый RPC установлен: $fastest_rpc с задержкой $min_latency секунд.${NC}"
    else
        echo -e "${RED}Ошибка: Не удалось определить самый быстрый RPC. Проверьте подключение к сети.${NC}"
        exit 1
    fi
}

# Основной цикл меню
while true; do
  clear
  echo -e "${GREEN}"
  cat << "EOL"
    ╦ ╦╔═╗╦═╗╔╦╗
    ║║║║ ║╠╦╝║║║
    ╚╩╝╚═╝╩╚═╩ ╩
    powered by EIP-7503
EOL
  echo -e "${NC}"

  echo -e "${GREEN}---- ИНСТРУМЕНТ ДЛЯ WORM MINER ----${NC}"
  echo -e "${BOLD}Выберите опцию:${NC}"
  echo "1. Установить майнер и запустить сервис"
  echo "2. Сжечь ETH для BETH"
  echo "3. Проверить балансы"
  echo "4. Обновить майнер"
  echo "5. Удалить майнер"
  echo "6. Запросить награды WORM"
  echo "7. Просмотреть логи майнера"
  echo "8. Найти и установить самый быстрый RPC"
  echo "9. Управление несколькими майнерами (PM2)"
  echo "10. Выход"
  echo -e "${GREEN}------------------------${NC}"
  read -p "Введите выбор [1-10]: " action

  case $action in
    1)
      echo -e "${GREEN}[*] Установка зависимостей...${NC}"
      sudo apt-get update && sudo apt-get install -y \
        build-essential cmake git curl wget unzip bc \
        libgmp-dev libsodium-dev nasm nlohmann-json3-dev

      if ! command -v cargo &>/dev/null; then
        echo -e "${GREEN}[*] Установка Rust toolchain...${NC}"
        curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y
        source "$HOME/.cargo/env"
      fi

      if ! command -v pm2 &>/dev/null; then
        echo -e "${GREEN}[*] Установка PM2 для управления процессами...${NC}"
        sudo apt-get install -y nodejs npm
        sudo npm install -g pm2
      fi

      echo -e "${GREEN}[*] Клонирование репозитория майнера...${NC}"
      cd "$HOME"
      if [ -d "$miner_dir" ]; then
        read -p "Директория $miner_dir существует. Удалить и переустановить? [y/N]: " confirm
        if [[ "$confirm" =~ ^[yY]$ ]]; then
          rm -rf "$miner_dir"
        else
          echo -e "${RED}Отмена установки.${NC}"
          exit 1
        fi
      fi
      if ! git clone https://github.com/worm-privacy/miner "$miner_dir"; then
        echo -e "${RED}Ошибка: Не удалось клонировать репозиторий. Проверьте сеть или права.${NC}"
        exit 1
      fi
      cd "$miner_dir"

      echo -e "${GREEN}[*] Скачивание параметров...${NC}"
      echo -e "${YELLOW}Это большой файл (~8 ГБ) и может занять несколько минут. Подождите...${NC}"
      make download_params

      echo -e "${GREEN}[*] Сборка и установка бинарника майнера...${NC}"
      RUSTFLAGS="-C target-cpu=native" cargo install --path .
      if [ ! -f "$worm_miner_bin" ]; then
        echo -e "${RED}Ошибка: Бинарник майнера не найден в $worm_miner_bin. Установка провалена.${NC}"
        exit 1
      fi

      echo -e "${GREEN}[*] Создание директории конфигурации...${NC}"
      mkdir -p "$log_dir"
      touch "$log_file"

      find_fastest_rpc

      # Запрос приватных ключей для 1 или 2 майнеров
      private_key1=""
      private_key2=""
      while true; do
        read -sp "Введите первый приватный ключ (например, 0x...): " private_key1
        echo ""
        if [[ $private_key1 =~ ^0x[0-9a-fA-F]{64}$ ]]; then
          break
        else
          echo -e "${YELLOW}Неверный формат ключа. Должен быть 64 hex-символа, начинающихся с 0x.${NC}"
        fi
      done
      echo "$private_key1" > "$key_file1"
      chmod 600 "$key_file1"

      read -p "Хотите добавить второй приватный ключ для второго майнера? [y/N]: " add_second
      if [[ "$add_second" =~ ^[yY]$ ]]; then
        while true; do
          read -sp "Введите второй приватный ключ (например, 0x...): " private_key2
          echo ""
          if [[ $private_key2 =~ ^0x[0-9a-fA-F]{64}$ ]]; then
            break
          else
            echo -e "${YELLOW}Неверный формат ключа. Должен быть 64 hex-символа, начинающихся с 0x.${NC}"
          fi
        done
        echo "$private_key2" > "$key_file2"
        chmod 600 "$key_file2"
      fi

      echo -e "${GREEN}[*] Предупреждение: Сделайте резервную копию файлов ключей в безопасном месте.${NC}"

      # Создание скриптов запуска для майнеров
      echo -e "${GREEN}[*] Создание скрипта запуска для первого майнера...${NC}"
      tee "$miner_dir/start-miner1.sh" > /dev/null <<EOL
#!/bin/bash
PRIVATE_KEY=\$(cat "$key_file1")
FASTEST_RPC=\$(cat "$fastest_rpc_file")
exec "$worm_miner_bin" mine \\
  --network sepolia \\
  --private-key "\$PRIVATE_KEY" \\
  --custom-rpc "\$FASTEST_RPC" \\
  --min-beth-per-epoch 0.0001 \\
  --max-beth-per-epoch 0.01 \\
  --assumed-worm-price 0.000002 \\
  --future-epochs 3
EOL
      chmod +x "$miner_dir/start-miner1.sh"

      if [ -n "$private_key2" ]; then
        echo -e "${GREEN}[*] Создание скрипта запуска для второго майнера...${NC}"
        tee "$miner_dir/start-miner2.sh" > /dev/null <<EOL
#!/bin/bash
PRIVATE_KEY=\$(cat "$key_file2")
FASTEST_RPC=\$(cat "$fastest_rpc_file")
exec "$worm_miner_bin" mine \\
  --network sepolia \\
  --private-key "\$PRIVATE_KEY" \\
  --custom-rpc "\$FASTEST_RPC" \\
  --min-beth-per-epoch 0.0001 \\
  --max-beth-per-epoch 0.01 \\
  --assumed-worm-price 0.000002 \\
  --future-epochs 3
EOL
        chmod +x "$miner_dir/start-miner2.sh"
      fi

      echo -e "${GREEN}[*] Запуск майнера(ов) через PM2...${NC}"
      pm2 start "$miner_dir/start-miner1.sh" --name miner1
      if [ -n "$private_key2" ]; then
        pm2 start "$miner_dir/start-miner2.sh" --name miner2
      fi
      pm2 save  # Для автозапуска после перезагрузки
      echo -e "${GREEN}[+] Майнер установлен и запущен успешно через PM2! Используйте 'pm2 list' для просмотра.${NC}"
      ;;
    2)
      echo -e "${GREEN}[*] Сжигание ETH для BETH${NC}"
      private_key=$(get_private_key "$key_file1") || exit 1  # По умолчанию первый ключ, можно адаптировать

      if [ ! -f "$fastest_rpc_file" ]; then
        find_fastest_rpc
      fi
      fastest_rpc=$(cat "$fastest_rpc_file")

      amount=""
      while true; do
        read -p "Введите сумму ETH для сжигания (например, 0.1, max 1): " amount
        if [[ "$amount" =~ ^[0-9.]+$ ]] && (( $(echo "$amount > 0 && $amount <= 1" | bc -l) )); then
          break
        else
          echo -e "${YELLOW}Неверная сумма. Должна быть числом > 0 и <= 1.${NC}"
        fi
      done

      fee=""
      while true; do
        read -p "Введите комиссию за сжигание (например, 0.001 ETH): " fee
        if [[ "$fee" =~ ^[0-9.]+$ ]] && (( $(echo "$fee >= 0" | bc -l) )); then
          spend=$(echo "$amount - $fee" | bc)
          if (( $(echo "$spend >= 0" | bc -l) )); then
            break
          else
            echo -e "${YELLOW}Комиссия не может быть больше суммы сжигания.${NC}"
          fi
        else
          echo -e "${YELLOW}Неверная комиссия. Должна быть положительным числом.${NC}"
        fi
      done

      wallet_address=$($worm_miner_bin info --network sepolia --private-key "$private_key" --custom-rpc "$fastest_rpc" | grep "burn-address" | awk '{print $4}')
      echo -e "${BOLD}Сжигание... | Комиссия: $fee ETH | Трата: $spend ETH | Получатель: $wallet_address${NC}"

      cd "$miner_dir"
      "$worm_miner_bin" burn \
        --network sepolia \
        --private-key "$private_key" \
        --custom-rpc "$fastest_rpc" \
        --amount "$amount" \
        --fee "$fee" \
        --spend "$spend"

      if [ ! -s "input.json" ] || [ ! -s "witness.wtns" ]; then
        echo -e "${YELLOW}Ошибка: Файлы доказательства (input.json, witness.wtns) не найдены или пусты.${NC}"
        echo -e "${YELLOW}Проверьте вывод майнера для деталей.${NC}"
      else
        echo -e "${GREEN}[+] Сжигание завершено. Файлы доказательства сгенерированы в $miner_dir.${NC}"
      fi
      ;;
    3)
      echo -e "${GREEN}[*] Проверка балансов...${NC}"
      private_key=$(get_private_key "$key_file1") || exit 1  # По умолчанию первый

      if [ ! -f "$fastest_rpc_file" ]; then
        find_fastest_rpc
      fi
      fastest_rpc=$(cat "$fastest_rpc_file")

      "$worm_miner_bin" info --network sepolia --private-key "$private_key" --custom-rpc "$fastest_rpc"
      ;;
    4)
      echo -e "${GREEN}[*] Обновление майнера...${NC}"
      if [ ! -d "$miner_dir" ]; then
        echo -e "${RED}Ошибка: Директория майнера $miner_dir не найдена. Сначала запустите опцию 1.${NC}"
        exit 1
      fi
      cd "$miner_dir"
      git pull origin main
      echo -e "${GREEN}[*] Сборка и установка бинарника майнера...${NC}"
      cargo clean
      RUSTFLAGS="-C target-cpu=native" cargo install --path .
      if [ ! -f "$worm_miner_bin" ]; then
        echo -e "${RED}Ошибка: Бинарник майнера не найден в $worm_miner_bin. Обновление провалено.${NC}"
        exit 1
      fi

      find_fastest_rpc

      pm2 restart all
      echo -e "${GREEN}[+] Майнер обновлен и перезапущен успешно.${NC}"
      ;;
    5)
      echo -e "${GREEN}[*] Удаление майнера...${NC}"
      pm2 delete all || true
      rm -rf "$log_dir" "$miner_dir" "$worm_miner_bin"
      echo -e "${GREEN}[+] Майнер удален.${NC}"
      ;;
    6)
      echo -e "${GREEN}[*] Запрос наград WORM...${NC}"
      private_key=$(get_private_key "$key_file1") || exit 1

      if [ ! -f "$fastest_rpc_file" ]; then
        find_fastest_rpc
      fi
      fastest_rpc=$(cat "$fastest_rpc_file")

      read -p "Введите начальную эпоху (например, 0): " from_epoch
      read -p "Введите количество эпох для запроса (например, 10): " num_epochs
      if [[ ! "$from_epoch" =~ ^[0-9]+$ ]] || [[ ! "$num_epochs" =~ ^[0-9]+$ ]]; then
        echo -e "${YELLOW}Ошибка: Значения эпох должны быть неотрицательными целыми числами.${NC}"
        continue
      fi
      "$worm_miner_bin" claim --network sepolia --private-key "$private_key" --custom-rpc "$fastest_rpc" --from-epoch "$from_epoch" --num-epochs "$num_epochs"
      echo -e "${GREEN}[+] Процесс запроса наград WORM завершен.${NC}"
      ;;
    7)
      echo -e "${GREEN}[*] Отображение последних 15 строк логов майнера...${NC}"
      if [ -f "$log_file" ]; then
        tail -n 15 "$log_file"
      else
        echo -e "${YELLOW}Файл логов не найден. Майнер установлен и запущен?${NC}"
      fi
      ;;
    8)
      echo -e "${GREEN}[*] Поиск и установка самого быстрого RPC...${NC}"
      find_fastest_rpc
      ;;
    9)
      echo -e "${GREEN}[*] Управление несколькими майнерами через PM2...${NC}"
      echo -e "${BOLD}Команды PM2 для управления:${NC}"
      echo "pm2 list - Просмотреть все процессы"
      echo "pm2 logs miner1 - Логи первого майнера"
      echo "pm2 logs miner2 - Логи второго майнера"
      echo "pm2 stop miner1 - Остановить первый"
      echo "pm2 start miner1 - Запустить первый"
      echo "pm2 restart all - Перезапустить все"
      echo "Если нужно добавить/изменить ключи, перезапустите опцию 1."
      ;;
    10)
      echo -e "${GREEN}[*] Выход...${NC}"
      exit 0
      ;;
    *)
      echo -e "${YELLOW}Неверный выбор. Введите число от 1 до 10.${NC}"
      ;;
  esac

  echo -e "\n${GREEN}Нажмите Enter для возврата в меню...${NC}"
  read
done
