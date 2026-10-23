-- Arrange like "Arrange Nodes", and route links that skip 3+ columns through PipeRouters
-- named NARouter. Arranging again without routers removes them.
require("NodeArrange").run(comp, { routers = true })
