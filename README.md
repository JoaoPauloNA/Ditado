# Ditado

App pessoal de ditado para macOS, com transcrição local ou por API e revisão
opcional usando uma conexão já cadastrada no Painel CLI. O Ditado é separado da
central: não instala, inicia, encerra nem modifica proxies ou logins do Painel.

## Compilar e abrir

Requer Mac com Apple Silicon, macOS 14 ou posterior e Xcode Command Line Tools.
Não há dependências externas para compilar.

```sh
python3 scripts/test.py
python3 scripts/build.py --open
```

O aplicativo fica em `build/Ditado.app`. Pode ser movido para `~/Applications`.
Permanece na barra de menus quando a janela é fechada. Para encerrar, use Sair.

## Primeiro ditado

Clique no microfone ou pressione **Control + Shift + Espaço** para iniciar.
Repita para parar e transcrever. O macOS solicitará acesso ao microfone e, se
escolhido, ao reconhecimento de fala. A gravação só começa por ação do usuário.
Selecione o campo de texto no aplicativo de destino e use o atalho para ditar.
Ao terminar, o texto é colado automaticamente naquele campo, substituindo a
seleção ou inserindo na posição do cursor. O texto também fica copiado.

Na primeira vez, clique em **Permitir colagem automática** e habilite **Ditado**
em **Ajustes do Sistema → Privacidade e Segurança → Acessibilidade**. Essa
permissão do macOS é necessária para inserir texto em outros aplicativos.
O controle fica em **Conexões → Neste Mac → Colar automaticamente no campo
selecionado**, ativado por padrão, inclusive nas configurações da versão anterior.

O destino é capturado antes de abrir as permissões de voz/microfone. O app guarda
somente o elemento focado e a posição da seleção, sem ler o texto do campo.
Se você iniciar pelo botão do Ditado, ele usa o campo do último aplicativo
externo. Ao terminar, retorna ao aplicativo de destino apenas se o Ditado ainda
estiver em primeiro plano. Se você mudar para outro aplicativo, outro campo ou
outra posição de cursor, o resultado fica copiado para colagem manual com
**Command + V**. O mesmo acontece quando a permissão de Acessibilidade faltar.

A inserção usa `AXSelectedText` quando disponível. Para editores que não aceitam
essa escrita, envia **Command + V** exclusivamente ao processo de destino
validado, sem eventos globais de teclado. Veja a [API de Acessibilidade da Apple](https://developer.apple.com/documentation/applicationservices/axuielement_h).

O áudio é WAV PCM de 16 kHz, mono, 16 bits. Cada ditado dura até cinco minutos.
O indicador de volume usa a medição real do microfone. A transcrição acontece
depois de parar; esta versão não oferece transcrição parcial ao vivo.

## Alterar o atalho

Em **Conexões → Neste Mac → Atalho global**, clique em **Alterar atalho…**.
Escolha a tecla e pelo menos dois modificadores, incluindo Control ou Command.
O padrão continua sendo **Control + Shift + Espaço**. A combinação escolhida
aparece no painel e no menu do Ditado. A tela permite voltar ao padrão,
verificar novamente a disponibilidade e cancelar sem mudar a configuração.

Antes de salvar, o Ditado bloqueia combinações comuns de aplicativos, verifica
os atalhos habilitados do macOS com `CopySymbolicHotKeys` e testa se existe uma
reserva global exclusiva. O novo registro e a gravação da configuração precisam
funcionar antes que o registro anterior seja removido. Um erro de registro ou
de persistência mantém o atalho anterior ativo. Eventos pendentes do atalho
anterior são ignorados após uma troca. A gravação fica suspensa enquanto a
tela de alteração estiver aberta.

**Limite da detecção:** o macOS aceita registros globais não exclusivos da
mesma combinação por vários apps e não expõe um catálogo completo desses
registros nem de todos os atalhos internos de aplicativos. A ausência de erro
de registro não prova ausência de conflito. Por isso a interface diz "nenhum
conflito detectado nas verificações disponíveis" e recomenda testar a combinação
nos programas utilizados. Após a sondagem, o registro ativo do Ditado é não
exclusivo, para não silenciar permanentemente outro aplicativo. A implementação
nunca altera os atalhos configurados no macOS ou em outros programas.

`python3 scripts/test-shortcuts.py` testa políticas, atalhos simbólicos reais,
conflito com reserva exclusiva em outro processo, preservação do registro antigo
quando a gravação da configuração falha e liberação do registro antigo após a
troca. Um segundo processo de teste confirma explicitamente a limitação dos
registros não exclusivos. Nenhuma tecla é enviada e nenhuma gravação é iniciada.

## Conexões de voz

- **Local · macOS:** padrão inicial. Usa `SFSpeechRecognizer` com reconhecimento
  no dispositivo obrigatório. Se o idioma/modelo local não estiver disponível,
  exibe orientação e não troca silenciosamente para processamento remoto.
- **Local · Whisper:** conecta a um `whisper-server` já em execução no Mac,
  normalmente em `http://127.0.0.1:8080/inference`. O servidor precisa ter um
  modelo Whisper carregado; o app não baixa nem instala modelos nesta versão.
- **API de transcrição:** endereço completo, modelo e chave configuráveis.
  Aceita o contrato multipart de `/audio/transcriptions`, com resposta JSON
  contendo `text`. O exemplo inicial usa `whisper-1`; serviços/modelos compatíveis
  podem ser configurados. A chave fica no Chaves do macOS por endereço de API.
  O áudio sai do Mac neste modo; requer as credenciais e os limites do serviço.

Referências: [reconhecimento no dispositivo da Apple](https://developer.apple.com/documentation/speech/sfspeechrecognizer/supportsondevicerecognition),
[API de transcrição](https://developers.openai.com/api/reference/resources/audio/subresources/transcriptions/methods/create),
[servidor whisper.cpp](https://github.com/ggml-org/whisper.cpp/blob/master/examples/server/README.md).

## Painel CLI como central

Em **Conexões → Painel CLI**, atualize os perfis, selecione um perfil e clique
em **Buscar modelos**. Ative o proxy no Painel se estiver parado. O Ditado consulta
`/v1/models` desse perfil usando apenas a chave de cliente correspondente.

Ative **Corrigir pontuação e pequenos erros** para enviar o texto transcrito ao
modelo escolhido por `/v1/chat/completions`. A transcrição de voz continua sendo
feita pelo mecanismo escolhido acima. Os modelos de texto do CLIProxy não são
tratados como modelos de transcrição de áudio. A compatibilidade de cada modelo
com chat completions depende do serviço; aparecer no catálogo não garante
suporte a todas as operações.

A integração lê o catálogo em
`~/Library/Application Support/PainelCli/CLIProxy/profiles.json` e, apenas quando
necessário para o perfil selecionado, sua porta e chave de cliente. Não lê
credenciais OAuth nem chaves de gerenciamento. Valida UUID, proprietário,
permissões e arquivos sem seguir symlinks nas instâncias. Usa endereços loopback
e não imprime chaves. Não requer mudanças no código ou na versão do Painel.

Se a revisão falhar, o ditado original continua disponível e é copiado. Se a
transcrição falhar, o áudio fica temporariamente disponível para tentar de novo
até cancelar, iniciar outro ditado ou encerrar normalmente o aplicativo.

## Dados locais

Configurações e até 100 textos ficam em
`~/Library/Application Support/Ditado`, em arquivos privados. Não contêm a chave
de API. O histórico pode ser desativado e apagado pela interface. Áudios
temporários são apagados ao concluir, cancelar ou encerrar normalmente. Um
encerramento forçado do sistema pode deixar o WAV na pasta temporária do macOS.

Os testes usam áudio e perfis sintéticos e transporte HTTP simulado. Não capturam
o microfone, acessam o Chaves, usam logins reais nem fazem chamadas externas.
O primeiro ditado e as conexões reais devem ser conferidos com os acessos e o
modelo escolhidos pelo usuário.

`python3 scripts/test-paste.py` verifica inserção nativa em uma janela de teste
isolada, em segundo plano: substituição de seleção, cursor vazio, Unicode,
destino alterado, falta de permissão e cancelamento. Requer Acessibilidade para
o processo que executa o teste. Somente o texto sintético da janela é editado;
nenhum atalho global é enviado e o microfone não é usado.
