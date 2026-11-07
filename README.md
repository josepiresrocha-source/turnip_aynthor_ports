# Turnip Thor Ports

Driver Vulkan Turnip (Mesa) montado para o **AYN Thor Max** (Snapdragon 8 Gen 2, **Adreno 740**, 16 GB, Android 13) e focado em **ports de console**: Forza Horizon 2 Recompiled e Uncharted: The Nathan Drake Collection.

Objetivo desta primeira versão: **menos engasgos e mais FPS**, os dois problemas que você relatou.

---

## 1. Por que não partir do "Turnip Gen8 V38"

- "Gen8" = Adreno **8xx** (Snapdragon 8 Elite). O Thor tem uma Adreno **740**, da geração **7xx**. O V38 roda nela porque o Turnip inclui todas as gerações, mas a pilha "gen8" quase não toca na A740.
- Os dois bugs da pilha gen8 que **afetam a A740** são:
  - o teste `is_a830` sempre verdadeiro, que faz o driver **ignorar `sampleShadingEnable` em todas as GPUs**. O FH2 depende disso para copiar render targets com MSAA amostra por amostra (`render_target_cache.cpp`, `pipeline_cache.cpp`);
  - **64 KiB de memória compartilhada anunciados**, quando o hardware só programa 32 KiB.
- A base do V38 (Mesa `f28352d117`, 16/out) está **1.337 commits atrás** do Mesa atual. Nesse intervalo entrou, por exemplo, o workaround de hardware `QCTDD08049535` para **a7xx gen1/gen2**: sem ele, varyings podem vir com lixo (corrigiu corrupção em Devil May Cry 5). A A740 é a7xx **gen2**.

Por isso este driver parte do **Mesa main de 06/nov/2026 (`21bbed37`)** puro, sem a pilha gen8, e acrescenta só o que é útil para a A740 e para os ports.

## 2. Contexto: de onde vem esse driver

| Quando | O quê |
|---|---|
| 2012+ | **Freedreno**: driver OpenGL aberto para Adreno, por engenharia reversa (Rob Clark). |
| mar/2019 | **Turnip** entra no Mesa (19.1), escrito no Google (Bas Nieuwenhuizen, Chia-I Wu), para Adreno 5xx/6xx. A Igalia vira a principal mantenedora. |
| 2020–2022 | Backend **KGSL**: o Turnip passa a rodar sobre o driver de kernel da Qualcomm no Android, sem precisar de um kernel Linux "puro". |
| 2022 | **libadrenotools** (bylaws, do emulador Skyline): apps carregam um driver Vulkan próprio sem root. Nasce o ecossistema de zips com `meta.json` (K11MCH1, MrPurple, StevenMXZ, whitebelyash...). |
| set/2023 | **Suporte inicial a A730/A740** (Mesa 23.3). Depois vieram tiling (GMEM), concurrent binning e um autotuner novo. |
| 2026 | Suporte a **A8xx** (Snapdragon 8 Elite) com a Qualcomm contribuindo diretamente. As builds "Gen8" da comunidade empilham patches experimentais em cima disso. |

## 3. Como os dois ports usam o driver (lido no código-fonte deles)

**Forza Horizon 2 Recompiled** (recompilação estática do Xbox 360, SDK rexglue derivado do Xenia)
- Identifica-se ao Vulkan como **`Xenia`**.
- O Turnip não expõe *fragment shader interlock*, então o FH2 usa o caminho **host render targets**: a EDRAM do Xbox 360 vira render targets Vulkan, com muitas transferências e *resolves* entre passes.
- O próprio projeto documenta medições na **Adreno 740** (Galaxy S23, Odin 2): *clears* fora do pass custando 16–21 ms de GPU, e alpha-to-coverage de hardware gerando "farinha" (pontos espalhados) na folhagem.
- Ele salva o próprio `VkPipelineCache`.

**Uncharted: The Nathan Drake Collection** (uncharted_pc + FEX + renderer shadPS4)
- Identifica-se como **`shadPS4`**. O código x86-64 roda no FEX, e a renderização é Vulkan nativa.
- Traz um Turnip próprio: Mesa 26.2.5 + patches feitos e testados no **Retroid Pocket G2** (Adreno A735), que é outra GPU.
- **Não salva o `VkPipelineCache`**: cria um vazio a cada execução. Com o cache em disco do Mesa desligado no Android, **o driver recompila todo shader em toda sessão**, e cada área nova engasga de novo.
- Usa o limite de memória compartilhada anunciado pelo driver para decidir se manda LDS para um buffer comum (`SharedMemoryToStoragePass`).

## 4. O que este driver muda

### Patch 1: cache de shaders em disco no Android (engasgos)
No Android, o cache em disco do Mesa vem **desligado** e, mesmo ligado, não tem onde gravar (apps não têm `HOME` nem `XDG_CACHE_HOME`). O patch:
- usa a pasta de cache do próprio app (`/data/user/<usuário>/<pacote>/cache/mesa_shader_cache`);
- liga o cache por padrão quando essa pasta existe e é gravável.

Efeito esperado: a **segunda vez** que um shader aparece (mesmo em outra sessão) ele vem do disco, sem compilar. Principalmente no Uncharted. O cache é apagado em *Configurações → Apps → Limpar cache*, e `MESA_SHADER_CACHE_DISABLE=true` desliga.

### Patch 2: GPU boost via KGSL (engasgos e FPS)
O KGSL permite que um contexto peça o nível máximo de clock (`KGSL_PROP_PWR_CONSTRAINT` / `PWR_MAX`). Conferi no código do kernel da plataforma SM8550:
- o pedido é aplicado a cada submissão, inclusive no caminho `gen7_hwsched` da A740;
- **expira sozinho** quando o trabalho do contexto termina;
- **continua respeitando o limite térmico**.

Ou seja, não é uma mudança global do aparelho: vale enquanto o jogo está renderizando. Isso tira o atraso do governor para subir o clock quando a cena pesa, um causador clássico de engasgo. O Thor tem ventoinha, o que torna essa troca (mais consumo e calor) razoável.
- Opção de driconf `tu_kgsl_gpu_boost` (desligada por padrão) e variável `TU_KGSL_GPU_BOOST=0/1`.

### Patch 3: perfis automáticos para os ports
Ativados só quando o app se identifica como `Xenia` ou `shadPS4`. Nenhum outro jogo é afetado (testado).

| Opção | Xenia (FH2) | shadPS4 (Uncharted) | Por quê |
|---|---|---|---|
| `tu_autotune_algorithm` | `profiled` | `profiled` | Mede o tempo real de cada render pass em GMEM e em sysmem na sua GPU e escolhe o melhor por pass. Esses renderers não se parecem nem com jogos D3D (onde sysmem é o certo) nem com jogos Android. |
| `tu_kgsl_gpu_boost` | sim | sim | Patch 2. |
| `tu_emulate_alpha_to_coverage` | sim | — | Corrige a "farinha" na folhagem quando o FH2 usa alpha-to-coverage real. Custo zero quando desligado. O shadPS4 não usa A2C. |

### Compilação específica para o Thor
- **API 33** (Android 13). Compilar contra API mais nova pode referenciar funções da libc que o Android 13 não tem.
- **`-march=armv8.2-a+fp16+dotprod+rcpc -mtune=cortex-a715`**: atômicos LSE em uma instrução (confirmado no código gerado), afinado para os núcleos A715/A710 onde rodam as threads de render. **Não use este driver em celulares ARMv8.0 antigos.**

## 5. O que ficou de fora, e por quê

- **Pilha gen8**: feita para A8xx; trazia os bugs da seção 1.
- **Reverter o workaround D32S8 (receita A7xx do StevenMXZ)**: no Mesa atual esse workaround só vale para A6xx. Não há nada a reverter na A740.
- **`has_early_preamble=False`**: a receita A7xx aplica só a7xx **gen1**. A A740 é gen2.
- **Patches de IB2/alinhamento do Uncharted**: são para falhas do CP da **A735**, não da A740, e custam desempenho.
- **Recuperação de contexto KGSL do Uncharted** (o jogo continua após falhas da GPU em vez de fechar): útil contra crashes, que não são o seu problema agora. Precisaria ser portada à mão para o Mesa atual. Fica para uma próxima versão, se aparecer "device lost".
- **`enable_tp_ubwc_flag_hint`** (patch "OneUI"): depende da versão do driver Qualcomm do sistema. O padrão do Mesa para a A740 já é o compatível com a maioria dos aparelhos.

## 6. Variantes geradas

| Zip | Conteúdo | Para quê |
|---|---|---|
| **Turnip Thor Ports** | Os 3 patches, autotune `profiled` nos ports | **Comece por este** |
| Turnip Thor Ports SYSMEM | Igual, mas autotune `prefer_sysmem` nos ports | Se o `profiled` não ganhar em algum jogo |
| Turnip Thor Upstream | Mesa main puro, mesmas flags | Controle: mostra quanto os patches fazem |

## 7. Como testar no Thor

Os dois ports têm contador de FPS (FH2: overlay de desempenho; Uncharted: painel → FPS).

1. Instale os três zips pelo seletor de driver de cada port.
2. Para cada driver, no mesmo trecho de jogo:
   - jogue **2 minutos** antes de medir. O `profiled` precisa de alguns segundos por render pass para convergir;
   - anote o FPS médio e se houve engasgos.
3. **Teste do cache (Uncharted)**: feche o jogo, abra de novo e passe pela mesma área. Com "Thor Ports", os engasgos de shader da segunda vez devem sumir ou diminuir muito; com "Upstream", não.
4. Se alguma variante quebrar algo (glitch, crash), me diga qual, em qual jogo e em qual cena.

Se o launcher permitir variáveis de ambiente (o Uncharted aceita `env.txt`), dá para isolar cada mudança sem trocar de zip:
- `TU_KGSL_GPU_BOOST=0`: desliga o boost;
- `TU_AUTOTUNE_ALGO=bandwidth`, `prefer_sysmem` ou `prefer_gmem`: troca o autotune;
- `MESA_SHADER_CACHE_DISABLE=true`: desliga o cache em disco.

## 8. Como compilar

1. Crie um repositório no GitHub e envie esta pasta inteira, incluindo `.github/`.
2. Abra **Actions → Build Turnip Thor Ports → Run workflow**.
3. Os três zips saem como artefatos.

Para compilar localmente em Linux x86_64: `VARIANT=ports ./build.sh`.

## 9. O que foi verificado e o que não foi

**Verificado:**
- Os patches aplicam limpo sobre o Mesa `21bbed37` e geram exatamente a árvore esperada nas duas variantes.
- Build de teste (Linux, backend KGSL) compilado **sem erros e sem avisos novos**.
- O trecho exclusivo do Android passou por checagem de sintaxe com `-Wall`.
- **Teste em execução** dos perfis: o driver carregado com app `Xenia` ativa boost + profiled + A2C; com `shadPS4`, ativa boost + profiled; outros apps ficam sem mudança; o perfil DXVK existente não muda.

**Não verificado:**
- O build com o NDK não pôde ser feito aqui (o download do NDK é bloqueado neste ambiente). O próprio CI do Mesa compila o Turnip para Android, então o caminho é o padrão, mas a primeira execução do Actions é a confirmação.
- Nada foi testado na A740. Os ganhos são hipóteses fundamentadas, e o protocolo da seção 7 é o que vai medi-los.
