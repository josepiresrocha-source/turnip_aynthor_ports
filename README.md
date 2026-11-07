# Turnip Thor

Driver Vulkan Turnip (Mesa) montado para o **AYN Thor Max** (Snapdragon 8 Gen 2, **Adreno 740**, 16 GB, Android 13). Desde a v3 é um driver para **jogos e emuladores em geral**, com ajustes extras para os ports de console (Forza Horizon 2 Recompiled, Uncharted: The Nathan Drake Collection e outros baseados em Xenia e shadPS4).

## Novidades da v5: teste do "quadro fantasma" no Eden

**O problema:** no Zelda: Breath of the Wild, pelo Eden, dentro dos santuários aparece um quadro escuro, como uma sombra, parado na tela enquanto a câmera se mexe. Acontece com o Turnip (há relatos com várias versões) e não com o driver da Qualcomm.

**Suspeitas, pelo código do Eden e do Turnip:**
1. **Memória de blocos (GMEM).** O Turnip desenha a tela em blocos dentro da GPU e só grava na memória no fim. O Eden às vezes lê como textura uma imagem que ainda está sendo desenhada. Ele protege esse caso só para profundidade, não para cor, e não usa a extensão Vulkan que avisaria o driver (`VK_EXT_attachment_feedback_loop_layout`). Aí a GPU lê a cópia antiga, e um quadro velho fica "congelado" por cima.
2. **LRZ (teste de profundidade antecipado).** Se ele descartar desenhos por engano, sobra o quadro anterior na tela.

**O que a v5 traz:** uma opção nova, `tu_debug`, que aplica flags de `TU_DEBUG` só para um app pelo perfil do driver. Emuladores no Android não conseguem passar variáveis de ambiente, então até agora não havia como. O perfil do Eden (que se apresenta ao driver como `yuzu Emulator`) vem **vazio** no driver normal. Dois drivers de teste preenchem esse perfil:

| Zip | O que muda no Eden (e só no Eden) |
|---|---|
| **Turnip Thor v5** | Nada; é o driver normal |
| **Turnip Thor v5 Eden SYSMEM** | Desenha tudo direto na memória, sem blocos (`sysmem`) |
| **Turnip Thor v5 Eden NOLRZ** | Desliga o LRZ (`nolrz`) |

**Como testar:** instale os três no **Gerenciador de Driver da GPU** do Eden. Entre no mesmo santuário com cada um, um de cada vez.
- O fantasma **some com o SYSMEM**: a causa é a 1. Compare o FPS; se estiver bom, use esse driver no Zelda (ele só muda o Eden). A próxima versão pode limitar isso só aos desenhos que precisam.
- O fantasma **some com o NOLRZ**: a causa é a 2, e dá para atacar o LRZ especificamente.
- **Não some com nenhum:** o problema está em outro lugar (emulador ou outro recurso do driver), e eu preciso de mais detalhes.

Os outros apps continuam iguais nos três drivers.

## Novidades da v3

**O que o log do Uncharted mostrou (Thor, driver v2 CB):**
- O jogo renderiza em **1920×1080 nativo** e fica limitado pela GPU (~23–25 FPS). A tela roda a 60 Hz, então os quadros alternam entre 2 e 3 atualizações (33 e 50 ms), e isso aparece como tremido.
- Quando o FSR foi ligado em 1080p→1080p ("Native AA"), o FPS caiu de ~23 para ~18,7. Nessa configuração o FSR só adiciona custo.
- Memória folgada (3 GB RSS, 1,8 GB de GPU, 4,8 GB livres) e o cache de pipelines do próprio port funcionando (291 de 292 pré-carregados).

**O que encontrei no driver por causa disso:** o shadPS4 cria **toda** imagem com `MUTABLE_FORMAT` e sem lista de formatos. Na A740, o Turnip então força **layout LINEAR** (sem tiling) e sem compressão em todas essas imagens, **inclusive todas as texturas BC**. É o pior caso para cache e banda.

**Patch 5 (todos os apps, correção exata):** pela especificação, as views possíveis de uma imagem mutável têm o mesmo tamanho de texel. Medi nas tabelas do Turnip: formatos com "swap" (BGRA e afins, o motivo do LINEAR) só existem em 2, 3 e 4 bytes. Então texturas BC/ETC/ASTC e formatos de 1, 8 e 16 bytes (RGBA16F, RGBA32F, RG32...) voltam a ter tiling.

**Patch 6 (só nos perfis dos ports):** também mantém tiling nas imagens de 4 bytes sem swap (RGBA8, R11G11B10F, RGB10A2), as dos G-buffers e do HDR. Isso só é correto se o app nunca as vê como BGRA. Conferi nas tabelas de formato do shadPS4 e do Xenia que eles não fazem isso. Se acontecer, o sintoma seria **vermelho e azul trocados**, e para isso existe a variante **Safe**.

**Patch 7 (padrões do Thor):** boost de GPU e de L3 ligados para **todos** os apps (o driver só é carregado por jogos e emuladores) e concurrent binning ligado nos ports, onde ele rendeu +2–3 FPS.

---

## Perfil de GPU medido no Thor e v4

Medido com `BB_GPU_PROFILE=1` no Uncharted, cena pesada, 1920×1080, driver v3: 45 blocos de 5 s, **~46 ms de GPU por quadro (~21–22 FPS)**.

| Onde vai o tempo de GPU (das etapas listadas) | % |
|---|---|
| Passes em 1080p (alvos RGBA16F + profundidade D32S8) | 51% |
| Compute em tela cheia | 15% |
| GPU parada esperando a CPU (22 envios por quadro) | 11% |
| Sombras 2048×2048 | 10% |
| Leitura de volta da profundidade (4× por quadro) | 4% |
| Resto (compute menor, passes reduzidos, skinning) | 9% |

**Conclusão:** a GPU passa ~89% do tempo ocupada com a renderização do próprio jogo, e dois terços disso escalam com a resolução. Não há ajuste de driver que tire os ~35% de custo necessários para ir de ~22 a 30 FPS em 1080p. Em **1280×720** essas etapas caem para ~44% do custo, o que estima ~30–34 FPS. Com FSR a partir de 960×540, a estimativa passa de 35.

**v4:** o patch 8 adiciona um experimento para o maior custo medido. Os alvos RGBA16F de 1080p estão **sem compressão UBWC**, porque o shadPS4 cria todas as imagens como "mutáveis". Com `TU_MUTABLE_UBWC=1`, a compressão volta, confiando que o jogo não lê essas imagens com outro formato. Se ler, o efeito aparece corrompido, e é só tirar a variável. Vem **desligado**.

Chaves que podem ser testadas pelo campo de ambiente do launcher, sem recompilar:

| Variável | Efeito |
|---|---|
| `TU_MUTABLE_UBWC=1` | liga a compressão nas imagens mutáveis (experimental) |
| `TU_MUTABLE_TILING=0` | desliga o tiling opcional das imagens de 4 bytes (= variante Safe) |
| `TU_KGSL_GPU_BOOST=0` / `TU_KGSL_L3_BOOST=0` | desliga os boosts |
| `TU_DEBUG=nocb` | desliga o concurrent binning |
| `TU_AUTOTUNE_ALGO=bandwidth` | volta ao autotune padrão do Mesa |

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

**Atenção, ports que rodam o jogo como executável separado** (o TLOU, e possivelmente o Uncharted): nesse processo o patch não consegue descobrir o pacote do app, então o cache só liga com `MESA_SHADER_CACHE_DIR`. A edição Thor do TLOU já faz isso. No Uncharted, coloque no campo de ambiente do port (*ADVANCED → More environment*):
```
MESA_SHADER_CACHE_DIR=/data/user/0/dev.unchartedandroid/cache
```
Se o jogo já rodar dentro do processo do app, a linha aponta para a mesma pasta que o patch usaria; não atrapalha.

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
| `tu_kgsl_l3_boost` | sim | sim | Patch 4 (v2). |
| `tu_allow_concurrent_binning` | só na variante CB | só na variante CB | Patch 4 (v2). |
| `tu_emulate_alpha_to_coverage` | sim | — | Corrige a "farinha" na folhagem quando o FH2 usa alpha-to-coverage real. Custo zero quando desligado. O shadPS4 não usa A2C. |

### Patch 4 (v2): boost do cache L3 da CPU e gancho para concurrent binning (FPS)
Na v1, o modo sysmem não ajudou e o boost de GPU já está ligado. Se o FPS continua em 23–24, o limite provável é a **CPU**. O próprio FH2 documenta que, em celulares rápidos, o renderizador emulado é limitado pelo processamento de comandos na CPU; o Uncharted roda o código x86 do jogo traduzido pelo FEX.
- **Boost do L3**: o KGSL também aceita um pedido de frequência máxima para o **cache L3 da CPU** (`KGSL_PROP_L3_PWR_CONSTRAINT`). No kernel da plataforma SM8550, a A740 tem esse recurso (`ADRENO_L3_VOTE`). O pedido segue o mesmo caminho do boost de GPU e é retirado quando a GPU desliga. Com o L3 mais rápido, a latência de memória cai para as threads que emulam o console. Opção `tu_kgsl_l3_boost`, variável `TU_KGSL_L3_BOOST=0/1`.
- **Concurrent binning** (só na variante **CB**): a A7xx consegue fazer o binning da próxima etapa da cena em paralelo com a renderização da atual. O upstream deixa desligado porque piora jogos de PC; como nos seus testes o modo GMEM ganhou do sysmem, vale testar nos ports. Ajuda se o limite for a GPU.

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
| **Turnip Thor v5** | Os 9 patches | **Use este** |
| **Turnip Thor v5 Eden SYSMEM** | Os 9 patches; no Eden, tudo em `sysmem` | Teste do quadro fantasma (ver "Novidades da v5") |
| **Turnip Thor v5 Eden NOLRZ** | Os 9 patches; no Eden, sem LRZ | Teste do quadro fantasma |

O workflow gera esses três. O script ainda aceita `VARIANT=thor-safe`, `VARIANT=thor-nocb` e `VARIANT=upstream` (controle sem patches).

## 7. Como testar no Thor

Os dois ports têm contador de FPS (FH2: overlay de desempenho; Uncharted: painel → FPS).

1. Instale os três zips pelo seletor de driver de cada port.
2. Para cada driver, no mesmo trecho de jogo:
   - jogue **2 minutos** antes de medir. O `profiled` precisa de alguns segundos por render pass para convergir;
   - anote o FPS médio e se houve engasgos.
3. **Teste do cache (Uncharted)**: feche o jogo, abra de novo e passe pela mesma área. Com "Thor Ports", os engasgos de shader da segunda vez devem sumir ou diminuir muito; com "Upstream", não.
4. Se alguma variante quebrar algo (glitch, crash), me diga qual, em qual jogo e em qual cena.

Se o launcher permitir variáveis de ambiente (o Uncharted aceita `env.txt`), dá para isolar cada mudança sem trocar de zip:
- `TU_KGSL_GPU_BOOST=0`: desliga o boost de GPU;
- `TU_KGSL_L3_BOOST=0`: desliga o boost do L3;
- `TU_DEBUG=forcecb` ou `TU_DEBUG=nocb`: liga ou desliga o concurrent binning;
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
- **v2:** recompilado sem erros. No teste em execução, as duas variantes ativam o boost de L3 nos dois ports; a CB liga o concurrent binning só neles; outros apps continuam sem mudança. O pedido de L3 ao KGSL não pôde ser exercitado aqui (não há GPU Adreno neste ambiente).
- **v3:** recompilado sem erros. A tabela de "swap" por tamanho, gerada das tabelas reais do Turnip, deu {2, 3, 4} bytes. Num teste com formatos representativos, BC1/BC3/BC5/BC7, RGBA16F, RGBA32F, RG32 e R8 ficam com tiling, e RGBA8, R11G11B10F, RGB10A2, RG8 e R16F continuam LINEAR (regra do upstream). No teste em execução, os boosts valem para qualquer app e os ports recebem concurrent binning + tiling opcional + profiled; a variante Safe tira só o tiling opcional. A variante principal gera exatamente a árvore que foi compilada e testada.

**Não verificado:**
- O build com o NDK não é feito aqui (o download do NDK é bloqueado neste ambiente); o GitHub Actions já confirmou que ele funciona nas versões anteriores.
- Nada foi testado na A740. Os ganhos são hipóteses fundamentadas, e o protocolo da seção 7 é o que vai medi-los.
